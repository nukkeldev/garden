[[vk::binding(0, 2)]]
StructuredBuffer<float4> fragmentNormals;
[[vk::binding(0, 3)]]
uniform ConstantBuffer<float4x4> normalMat;

static float3 lightColor = float3(1.0, 0.0, 0.0);
static float3 lightPosition = float3(0.0, 3.0, 0.0);

// TODO: Import from vertex once you figure out how to not import uniforms.
struct VertexOutput
{
    float3 fragmentPosition;
    float3 color;
};

struct Fragment
{
    float4 color;
};

[shader("fragment")]
Fragment fragmentMain(
    uint fragmentID: SV_PrimitiveID,
    VertexOutput input: VertexOutput) : SV_Target
{
    // Ambient
    float ambientStrength = 0.1;
    float3 ambient = ambientStrength * lightColor;

    // Diffuse
    float3 norm = normalize(mul(normalMat, fragmentNormals[fragmentID]).xyz);
    float3 lightDirection = normalize(lightPosition - input.fragmentPosition);
    float diff = max(0.0, dot(norm, lightDirection));
    float3 diffuse = diff * lightColor;

    Fragment output;
    output.color = float4((ambient + diffuse) * input.color, 1.0);
    // output.color = float4(norm, 1.0);
    return output;
}
