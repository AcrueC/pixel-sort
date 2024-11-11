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
    Format = R32I;
};
sampler2D<int> samplerValue { Texture = texValue; };

// texture of span ids before sorting
texture2D texIDsIn {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R32I;
};
sampler2D<int> samplerIDsIn { Texture = texIDsIn; };
storage2D<int> targetIDsIn {
    Texture = texIDsIn;
    MipLevel = 0;
};

// texture of span ids after sorting
texture2D texIDsOut {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R32I;
};
sampler2D<int> samplerIDsOut { Texture = texIDsOut; };

// texture of image fully sorted
texture2D texFullSorted {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
};
sampler2D samplerFullSorted { Texture = texFullSorted; };

// texture of offsets for each value
texture2D texComputeOffset {
    Width = BUFFER_WIDTH;
    Height = 256;
    Format = R32I;
};
sampler2D<int> samplerComputeOffset { Texture = texComputeOffset; };
storage2D<int> targetComputeOffset {
    Texture = texComputeOffset;
    MipLevel = 0;
};

// proxy that holds addresses of pixels that when read results in a sorted image
texture2D texSortProxy {
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R32F;
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

uniform bool reversed < ui_type = "radio";
    ui_label = "Reversed";
    ui_tooltip = "Reverse sorting order";
    ui_category = "Pixel Sorting";
> = false;

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

float sortValue(float3 color) {
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
        out int value : SV_Target1) {
    float4 color = tex2D(samplerColor, texcoord);

    float maskValue = luminance(color.rgb);
    mask = (maskValue >= LowThreshold && maskValue <= HighThreshold) ? 1 : 0;
    mask = inverted ? 1 - mask : mask;

    float fvalue = sortValue(color.rgb);
    fvalue = reversed ? 1f - fvalue : fvalue;
    value = floor(fvalue * 256f);
    value = clamp(value, 0, 255);
}

// write the id(y of first pixel) of each consecutive span of pixels to a texture
// one thread per column
void indexIds(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    if (id.x >= BUFFER_WIDTH) {
        return;
    }

    bool inSpan = false;
    int spanId = 0;
    for (int i = 0; i < BUFFER_HEIGHT; i++) {
        float mask = tex2Dfetch(samplerMask, int2(id.x, i)).r;
        bool masked = (mask > 0f);

        spanId = (masked == inSpan) ? spanId : i;
        inSpan = masked;

        tex2Dstore(targetIDsIn, int2(id.x, i), spanId);
    }
}

// step one of radix sort, frequency analysis
// based on: https://gpuopen.com/download/publications/Introduction_to_GPU_Radix_Sort.pdf
// one thread per column * possible values (256)
void radixCount(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    if (id.x >= BUFFER_WIDTH) {
        return;
    }

    float count = 0;

    for (int i = 0; i < BUFFER_HEIGHT; i++) {
        int value = tex2Dfetch(samplerValue, int2(id.x, i)).r;
        count = (value == id.z) ? count + 1 : count;
    }

    tex2Dstore(targetComputeOffset, id.xz, count);
}

// first sum the counts stored before to get offsets
// then use those offset to sort the pixels, increment an offset each time it is
// used this pass does not actually sort the texture, but instead creates a
// proxy that works as a sort of adress book of correct pixel locations
// one thread per column
void radixReorder(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    if (id.x >= BUFFER_WIDTH) {
        return;
    }

    int offsetSums[256];
    int sum = 0;

    for (int n = 0; n < 256; n++) {
        int value = tex2Dfetch(samplerComputeOffset, int2(id.x, n)).r;
        offsetSums[n] = sum;
        sum = sum + value;
    }

    for (int i = 0; i < BUFFER_HEIGHT; i++) {
        int value = tex2Dfetch(samplerValue, int2(id.x, i)).r;
        int offset = offsetSums[value];
        float fi = i / float(BUFFER_HEIGHT);

        tex2Dstore(targetSortProxy, int2(id.x, offset), float4(fi, 0f, 0f, 1f));

        offset++;
        offsetSums[value] = offset;
    }
}

// using the texture created in the last step, sort both the original image and
// the span id texture
void fullSorter(float4 pos : SV_Position, 
        float2 texcoord : TEXCOORD0, 
        out float4 color : SV_Target0, 
        out int id : SV_Target1) {
    float target = tex2D(samplerSortProxy, texcoord).r;
    color = tex2D(samplerColor, float2(texcoord.x, target));
    id = tex2D(samplerIDsIn, float2(texcoord.x, target)).r;
}

// using the span Id texture, write the pixels back to their span, keeping a sum
// of the items added to each span as an additional offset this step currently
// uses alot of memory and can likely be improved 
// one thread per column
void sortToSpans(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID) {
    if (id.x >= BUFFER_WIDTH) {
        return;
    }

    int spanOffsets[BUFFER_HEIGHT];
    int sum = 0;

    for (int i = 0; i < BUFFER_HEIGHT; i++) {
        float4 color = tex2Dfetch(samplerFullSorted, int2(id.x, i));
        int spanId = tex2Dfetch(samplerIDsOut, int2(id.x, i)).r;
        int offset = spanOffsets[spanId] + spanId;

        tex2Dstore(targetComputeFinal, int2(id.x, offset), color);

        spanOffsets[spanId]++;
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

    pass p2 // radix count pass
    {
        DispatchSizeX = 64;
        DispatchSizeY = 1;
        DispatchSizeZ = 256;
        ComputeShader = radixCount<64, 1, 1>;
    }

    pass p3 // radix Reorder
    {
        DispatchSizeX = 60;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        ComputeShader = radixReorder<64, 1, 1>;
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
