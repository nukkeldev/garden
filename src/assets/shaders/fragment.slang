import "structs";

// Bindings

[[vk::binding(0, 2)]]
Sampler2D diffuseMap;
// SamplerState sampler;

[[vk::binding(1, 2)]]
StructuredBuffer<float4> fragmentNormals;
[[vk::binding(0, 3)]]
uniform ConstantBuffer<PerMeshFragmentData> pmd;
[[vk::binding(1, 3)]]
uniform ConstantBuffer<float3> viewPosition;

// Lighting

static float3 lightColor = float3(1.0, 1.0, 1.0);
static float3 lightPosition = float3(0.0, 5.0, 0.0);

static float specularity = 0.5;
static float ambientStrength = 0.2;

// Main

[shader("fragment")]
Fragment fragmentMain(
    uint fragmentID: SV_PrimitiveID,
    VertexOutput input: VertexOutput) : SV_Target
{
    // NOTE: Lighting calculations are done in **world space**.
    Material material = pmd.material;

    // Ambient
    float3 ambient = (ambientStrength * material.ambientColor) * lightColor;

    // Diffuse
    float3 norm;
    if (material.flatShading)
    {
        norm = normalize(mul((float3x3)pmd.normalMat, fragmentNormals[fragmentID].xyz));
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
    float3 viewDirection = normalize(viewPosition - input.fragmentPosition);
    float3 reflectedDirection = reflect(-lightDirection, norm);
    float spec = pow(max(dot(viewDirection, reflectedDirection), 0.0), material.specularExponent);
    float3 specular = (specularity * spec * material.specularColor) * lightColor;

    Fragment output;
    output.color = float4(ambient + diffuse + specular, 1.0);
    // output.color = float4(input.texcoord, 1, 1); // DEBUG TEXCOORDS
    // output.color = float4(input.normalDirection * 0.5 + 0.5, 1.0); // DEBUG NORMALS
    return output;
}
