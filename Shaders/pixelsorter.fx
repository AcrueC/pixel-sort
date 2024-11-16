// Masked Pixel Sorter
// idea based on https://www.youtube.com/watch?v=HMmmBDRy-jE
// TODO: horizontal, blur before masking, optimizations 
// (mainly around the compute shaders operations and memory usage)

#include "ReShade.fxh"
#include "ReShadeUI.fxh"

//--- texture definitions

// back buffer
texture2D texColorBuffer : COLOR;
sampler2D samplerColor { Texture = texColorBuffer; };

//depth
texture2D texDepthBuffer : DEPTH;
sampler2D samplerDepth { Texture = texDepthBuffer; };

// mask of which pixels should be sorted in the final image
texture2D texMask {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R8;
};
sampler2D samplerMask { Texture = texMask; };

// greyscale image of values to sort by
texture2D texValue {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R8;
};
sampler2D samplerValue { Texture = texValue; };

// texture of span ids before sorting
texture2D texIDsIn {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R16;
};
sampler2D samplerIDsIn { Texture = texIDsIn; };
storage2D targetIDsIn {
    Texture = texIDsIn;
    MipLevel = 0;
};

// texture of span ids after sorting
texture2D texIDsOut {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R16;
};
sampler2D samplerIDsOut { Texture = texIDsOut; };

// texture of image fully sorted
texture2D texFullSorted {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
};
sampler2D samplerFullSorted { Texture = texFullSorted; };

// proxy that holds addresses of pixels that when read results in a sorted image
texture2D texSortProxy {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R16F;
};
sampler2D samplerSortProxy { Texture = texSortProxy; };
storage2D targetSortProxy {
    Texture = texSortProxy;
    MipLevel = 0;
};

// image after sorting to spans
texture2D texComputeFinal {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
};
sampler2D samplerComputeFinal { Texture = texComputeFinal; };
storage2D targetComputeFinal {
    Texture = texComputeFinal;
    MipLevel = 0;
};

//--- Options

uniform float LowThreshold < __UNIFORM_SLIDER_FLOAT1 
    ui_min = -0.001f;
    ui_max = 1f;
    ui_step = 0.001;
    ui_label = "Low Threshold";
    ui_tooltip = "Low Threshold for a Luminance";
    ui_category = "Mask";
> = 0.2f;

uniform float HighThreshold < __UNIFORM_SLIDER_FLOAT2 
    ui_min = 0f;
    ui_max = 1.001f;
    ui_step = 0.001;
    ui_label = "High Threshold";
    ui_tooltip = "High Threshold for Luminance";
    ui_category = "Mask";
> = 0.7f;

uniform bool inverted < ui_type = "radio";
    ui_label = "Inverted";
    ui_tooltip = "Invert mask";
    ui_category = "Mask";
> = false;

uniform int sorter < ui_type = "combo";
    ui_label = "Sort by";
    ui_tooltip = "What value to sort by";
    ui_category = "Pixel Sorting";
    ui_items = "Hue\0"
        "Saturation\0"
        "Luminance\0"
        "Chroma\0"
        "Red\0"
        "Green\0"
        "Blue\0";
> = 2;

uniform bool horizontal < ui_type = "radio";
    ui_label = "Horizontal";
    ui_tooltip = "Horizontal sorting as opposed Vertical";
    ui_category = "Pixel Sorting";
> = false;

uniform bool reversed < ui_type = "radio";
    ui_label = "Reversed";
    ui_tooltip = "Reverse sorting order";
    ui_category = "Pixel Sorting";
> = false;

//--- define

#if BUFFER_HEIGHT > BUFFER_WIDTH
#define BUFFER_MAX BUFFER_HEIGHT
#else
#define BUFFER_MAX BUFFER_WIDTH
#endif

//--- Helper functions

// Various functions derived from https://en.wikipedia.org/wiki/HSL_and_HSV
float chroma(float3 color) {
    float maxV = max(color.r, max(color.g, color.b));
    float minV = min(color.r, min(color.g, color.b));
    return maxV - minV;
}

float hue(float3 color) {
    float maxV = max(color.r, max(color.g, color.b));
    float minV = min(color.r, min(color.g, color.b));
    float chromaV = maxV - minV;

    if (chromaV == 0f) {
        return 0f;
    }

    float hue = maxV == color.r ? (color.g - color.b) / chromaV : 0f;
    hue = maxV == color.g ? 2 + ((color.b - color.r) / chromaV) : hue;
    hue = maxV == color.b ? 4 + ((color.r - color.g) / chromaV) : hue;

    hue = ((hue / 6) + 1) % 1f;

    return hue;
}

// simplest implementation, is there a better one?
float saturation(float3 color) {
    float i = (color.r + color.g + color.b) / 3f;
    float minV = min(color.r, min(color.g, color.b));

    if (i == 0f) {
        return 0f;
    }
    return 1 - (minV / i);
}

// from https://en.wikipedia.org/wiki/Relative_luminance
float luminance(float3 color) {
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float switchValue(float3 color) {
    switch (sorter) {
    default:
        return hue(color);
    case 1:
        return saturation(color);
    case 2:
        return luminance(color);
    case 3:
        return chroma(color);
    case 4:
        return color.r;
    case 5:
        return color.g;
    case 6:
        return color.b;
    }
}

//--- Passes

// makes a double thresholded mask and writes a greyscale version of the image
void doubleThreshholdMaskAndValue(float4 pos : SV_Position, 
        float2 texcoord : TEXCOORD0, 
        out float mask : SV_Target0, 
        out float fvalue : SV_Target1) {

    float4 color = tex2D(samplerColor, texcoord);
    float maskValue = luminance(color.rgb);

    mask = (maskValue >= LowThreshold && maskValue <= HighThreshold) ? 1 : 0;
    mask = inverted ? 1 - mask : mask;

    fvalue = switchValue(color.rgb);

    fvalue = reversed ? 1f - fvalue : fvalue;
}

// write the id(y of first pixel) of each consecutive span of pixels to a
// texture one thread per column
void indexIds(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    int thread_count = horizontal?BUFFER_HEIGHT:BUFFER_WIDTH;
    int thread_length = horizontal?BUFFER_WIDTH:BUFFER_HEIGHT;
    if (id.x >= thread_count) {
        return;
    }

    bool inSpan = false;
    float spanId = 0f;

    for (int i = 0; i < thread_length; i++) {
        int2 coord = horizontal?int2(i, id.x):int2(id.x, i);
        float mask = tex2Dfetch(samplerMask, coord).r;
        bool masked = (mask > 0f);

        spanId = (masked == inSpan) ? spanId : float(i) / 4095f;
        inSpan = masked;
        tex2Dstore(targetIDsIn, coord, spanId);
    }
}

// radix sort
// based on
// https://gpuopen.com/download/publications/Introduction_to_GPU_Radix_Sort.pdf
// one thread per column, definately could be better
void radixSort(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    int thread_count = horizontal?BUFFER_HEIGHT:BUFFER_WIDTH;
    int thread_length = horizontal?BUFFER_WIDTH:BUFFER_HEIGHT;
    if (id.x >= thread_count) {
        return;
    }

    int counts[256];

    for (int i = 0; i < thread_length; i++) {
        int2 coord = horizontal?int2(i, id.x):int2(id.x, i);
        int value = round(tex2Dfetch(samplerValue, coord).r * 255);
        counts[value] += 1;
    }

    int sum = 0;

    for (int n = 0; n < 256; n++) {
        int value = counts[n];
        counts[n] = sum;
        sum = sum + value;
    }

    for (int i = 0; i < thread_length; i++) {
        int2 coord = horizontal?int2(i, id.x):int2(id.x, i);
        int value = round(tex2Dfetch(samplerValue, coord).r * 255f);
        int offset = counts[value];

        float fi = float(i) / 4095f;

        int2 coord2 = horizontal?int2(offset, id.x):int2(id.x, offset);

        tex2Dstore(targetSortProxy, coord2, float4(fi, 0f, 0f, 1f));

        offset++;
        counts[value] = offset;
    }
}

// using the texture created in the last step
// sort both the original image and the span id textures
void fullSorter(float4 pos : SV_Position, 
        float2 texcoord : TEXCOORD0, 
        out float4 color : SV_Target0, 
        out float id : SV_Target1) {
    int thread_length = horizontal?BUFFER_WIDTH:BUFFER_HEIGHT;
    float target = tex2D(samplerSortProxy, texcoord).r * 4095f;
    float2 coord = horizontal?int2(target, pos.y):float2(pos.x, target);
    color = tex2Dfetch(samplerColor, coord);
    id = tex2Dfetch(samplerIDsIn, coord).r;
}

// using the span Id texture, write the pixels back to their span, keeping a sum
// of the items added to each span as an additional offset 
// this step currently uses alot of memory and can likely be improved 
// one thread per column
void sortToSpans(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    int thread_count = horizontal?BUFFER_HEIGHT:BUFFER_WIDTH;
    int thread_length = horizontal?BUFFER_WIDTH:BUFFER_HEIGHT;
    if (id.x >= thread_count) {
        return;
    }

    int spanOffsets[BUFFER_MAX];
    int sum = 0;

    for (int i = 0; i < thread_length; i++) {
        int2 coord = horizontal?int2(i, id.x):int2(id.x, i);
        float4 color = float4(tex2Dfetch(samplerFullSorted, coord).rgb , 1f);

        int spanId = tex2Dfetch(samplerIDsOut, coord).r * 4095f;

        int offset = spanOffsets[spanId] + spanId;

        int2 coord2 = horizontal?int2(offset, id.x):int2(id.x, offset);
        tex2Dstore(targetComputeFinal, coord2, color);

        spanOffsets[spanId] += id.y==1?-1:1;
    }
}

// write the sorted image to the back buffer masked by the mask
void flip(float4 pos : SV_Position, 
        float2 texcoord : TEXCOORD0, 
        out float4 color : SV_Target) {
    bool masked = tex2D(samplerMask, texcoord).r > 0f;
    color = masked ? tex2D(samplerComputeFinal, texcoord)
                   : tex2D(samplerColor, texcoord);
}

//--- Technique

technique pixelSort {
    pass p0 // mask and value
    {
        VertexShader = PostProcessVS;
        PixelShader = doubleThreshholdMaskAndValue;
        RenderTarget0 = texMask;
        RenderTarget1 = texValue;
    }

    pass p1 // Index span Ids
    {
        DispatchSizeX = 64;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        ComputeShader = indexIds<64, 1, 1>;
    }

    pass p3 // radix sort
    {
        DispatchSizeX = 64;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        ComputeShader = radixSort<64, 1, 1>;
    }

    pass p4 // full sorter
    {
        VertexShader = PostProcessVS;
        PixelShader = fullSorter;
        RenderTarget0 = texFullSorted;
        RenderTarget1 = texIDsOut;
    }

    pass p5 // sort back to spans
    {
        DispatchSizeX = 64;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        ComputeShader = sortToSpans<64, 1, 1>;
    }

    pass p6 // write to back buffer
    {
        VertexShader = PostProcessVS;
        PixelShader = flip;
    }
}
