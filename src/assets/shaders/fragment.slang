struct Light
{
    float3 position;
    float3 color;
}

// TODO: Import from vertex once you figure out how to not import uniforms.
struct VertexOutput
{
    float3 color;
};

struct Fragment
{
    float4 color;
};

[shader("fragment")]
Fragment fragmentMain(
    VertexOutput input: VertexOutput) : SV_Target
{
    Fragment output;
    output.color = float4(input.color, 1.0);
    return output;
}
