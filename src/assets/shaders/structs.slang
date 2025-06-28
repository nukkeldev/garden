// Per-Mesh Data

struct PerMeshVertexData
{
    float4x4 model;
    float4x4 normalMat;
}

struct PerMeshFragmentData
{
    float4x4 normalMat;
    Material material;
}

// Per-Frame Data

struct PerFrameVertexData
{
    float4x4 view_proj;
}

// Vertex Data

struct VertexInput
{
    float3 position : POSITION;
    float3 normal : NORMAL;
};

struct VertexOutput
{
    float3 fragmentPosition;
    float3 normalDirection;
};

struct VertexStageOutput
{
    float4 sv_position : SV_Position;
    VertexOutput vertex : VertexOutput;
};

// Fragment Data

struct Fragment
{
    float4 color;
};

// Materials

struct Material
{
    bool flatShading;

    float3 ambientColor;
    float3 diffuseColor;
    float3 specularColor;
    float specularExponent;
}
