// -- Vertex -- //

[[vk::binding(0, 1)]]
uniform ConstantBuffer<PerMeshVertexData> perMeshVertexData;
[[vk::binding(1, 1)]]
uniform ConstantBuffer<PerFrameVertexData> perFrameVertexData;

[shader("vertex")]
VertexStageOutput vertexMain(VertexInput input)
{
    VertexStageOutput output;

    output.vertex.fragmentPosition = mul(perMeshVertexData.model, float4(input.position, 1.0)).xyz;
    output.vertex.normalDirection = normalize(mul((float3x3)perMeshVertexData.normalMat, input.normal));
    output.vertex.texcoord = input.texcoord;
    output.sv_position = mul(perFrameVertexData.view_proj, float4(output.vertex.fragmentPosition, 1.0));

    return output;
}

// -- Fragment -- //

[[vk::binding(0, 2)]]
Sampler2D diffuseMap;
// SamplerState sampler;

[[vk::binding(1, 2)]]
StructuredBuffer<float4> fragmentNormals;
[[vk::binding(0, 3)]]
uniform ConstantBuffer<PerMeshFragmentData> perMeshFragmentData;
[[vk::binding(1, 3)]]
uniform ConstantBuffer<PerFrameFragmentData> perFrameFragmentData;

static float specularity = 0.5;
static float ambientStrength = 0.2;

[shader("fragment")]
Fragment fragmentMain(
    uint fragmentID: SV_PrimitiveID,
    VertexOutput input: VertexOutput) : SV_Target
{
    // NOTE: Lighting calculations are done in **world space**.
    Material material = perMeshFragmentData.material;

    if (material.basic)
    {
        Fragment output;
        output.color = float4(material.diffuseColor, 1.0);
        return output;
    }

    float3 color = float3(0.0, 0.0, 0.0);

    for (int i = 0; i < perFrameFragmentData.lightCount; ++i)
    {
        float3 lightColor = perFrameFragmentData.lights[i].color;
        float3 lightPosition = perFrameFragmentData.lights[i].position;

        // Ambient
        float3 ambient = (ambientStrength * material.ambientColor) * lightColor;

        // Diffuse
        float3 norm;
        if (material.flatShading)
        {
            norm = normalize(mul((float3x3)perMeshFragmentData.normalMat, fragmentNormals[fragmentID].xyz));
        }
        else
        {
            norm = input.normalDirection;
        }

        float3 lightDirection = normalize(lightPosition - input.fragmentPosition);
        float diff = max(0.0, dot(norm, lightDirection));
        float3 diffuseColor = diffuseMap.Sample(float2(input.texcoord.x, 1 - input.texcoord.y)).xyz;
        float3 diffuse = (diff * diffuseColor) * lightColor;

        // Specular
        float3 viewDirection = normalize(perFrameFragmentData.viewPosition - input.fragmentPosition);
        float3 reflectedDirection = reflect(-lightDirection, norm);
        float spec = pow(max(dot(viewDirection, reflectedDirection), 0.0), material.specularExponent);
        float3 specular = (specularity * spec * material.specularColor) * lightColor;

        color += ambient + diffuse + specular;
    }

    Fragment output;
    output.color = float4(color, 1.0);
    // output.color = float4(input.texcoord, 1, 1); // DEBUG TEXCOORDS
    // output.color = float4(input.normalDirection * 0.5 + 0.5, 1.0); // DEBUG NORMALS
    return output;
}

// -- Structs -- //

// Vertex

struct PerFrameVertexData
{
    float4x4 view_proj;
}

struct PerMeshVertexData
{
    float4x4 model;
    float4x4 normalMat;
}

struct VertexInput
{
    float3 position : POSITION;
    float3 normal : NORMAL;
    float2 texcoord : TEXCOORD;
};

struct VertexOutput
{
    float3 fragmentPosition;
    float3 normalDirection;
    float2 texcoord;
};

struct VertexStageOutput
{
    float4 sv_position : SV_Position;
    VertexOutput vertex : VertexOutput;
};

// Fragment

struct PerFrameFragmentData
{
    Light lights[16];
    uint32_t lightCount;
    float3 viewPosition;
}

struct PerMeshFragmentData
{
    float4x4 normalMat;
    Material material;
}

struct Fragment
{
    float4 color;
};

// Materials

struct Material
{
    bool basic;
    bool flatShading;

    float3 ambientColor;
    float3 diffuseColor;
    float3 specularColor;
    float specularExponent;
}

// Light

struct Light
{
    float3 position;
    float3 color;
}
