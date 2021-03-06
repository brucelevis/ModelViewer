#pragma sokol @ctype vec3 Eigen::Vector3f
#pragma sokol @ctype vec4 Eigen::Vector4f
#pragma sokol @ctype mat4 Eigen::Matrix4f

#pragma sokol @vs shading_vs
in vec2 position;
in vec2 uv;

out vec2 v_uv;

void main() {
  gl_Position = vec4(position, 0.0, 1.0);
  v_uv = uv;
}
  #pragma sokol @end

  #pragma sokol @fs shading_fs
in vec2 v_uv;

out vec4 color;
out vec4 bright_color;

uniform shading_fs_params {
  vec3 view_pos;
  vec3 light_direction;
  mat4 light_matrix;
};

uniform sampler2D g_world_pos;
uniform sampler2D g_normal;
uniform sampler2D g_albedo;
uniform sampler2D g_emissive;
uniform sampler2D shadow_map;
uniform sampler2D ao_map;
uniform samplerCube irradiance_map;
uniform samplerCube prefilter_map;
uniform sampler2D brdf_lut;

const float PI = 3.14159265359;

float decode_depth(vec4 rgba) {
  return dot(rgba, vec4(1.0, 1.0/255.0, 1.0/65025.0, 1.0/160581375.0));
}

float calculate_shadow(vec3 world_pos, float bias) {
  vec4 light_space_postion = light_matrix * vec4(world_pos, 1.0f);
  vec3 projection_coords = light_space_postion.xyz / light_space_postion.w;
  projection_coords = projection_coords * 0.5 + 0.5;

  float closest_depth = decode_depth(texture(shadow_map, projection_coords.xy));
  float current_depth = projection_coords.z;

  float shadow = (current_depth - bias) > closest_depth  ? 1.0 : 0.0;
  return shadow;
}

float DistributionGGX(vec3 N, vec3 H, float roughness) {
  float a      = roughness*roughness;
  float a2     = a*a;
  float NdotH  = max(dot(N, H), 0.0);
  float NdotH2 = NdotH*NdotH;

  float num   = a2;
  float denom = (NdotH2 * (a2 - 1.0) + 1.0);
  denom = PI * denom * denom;

  return num / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness) {
  float r = (roughness + 1.0);
  float k = (r*r) / 8.0;

  float num   = NdotV;
  float denom = NdotV * (1.0 - k) + k;

  return num / denom;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
  return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

vec3 fresnel_schlick_roughness(float cos_theta, vec3 F0, float roughness) {
  return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cos_theta, 5.0);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
  float NdotV = max(dot(N, V), 0.0);
  float NdotL = max(dot(N, L), 0.0);
  float ggx2  = GeometrySchlickGGX(NdotV, roughness);
  float ggx1  = GeometrySchlickGGX(NdotL, roughness);

  return ggx1 * ggx2;
}

vec3 indirect_lighting(vec3 normal, vec3 view_dir, vec3 F0, float roughness, vec3 albedo) {
  vec3 reflected = reflect(-view_dir, normal);
  const float MAX_REFLECTION_LOD = 4.0;
  vec3 prefiltered_color = textureLod(prefilter_map, reflected, roughness * MAX_REFLECTION_LOD).rgb;
  vec3 F = fresnel_schlick_roughness(max(dot(normal, view_dir), 0.0), F0, roughness);
  vec2 env_brdf  = texture(brdf_lut, vec2(max(dot(normal, view_dir), 0.0), roughness)).rg;
  vec3 specular = prefiltered_color * (F * env_brdf.x + env_brdf.y);

  vec3 kS = F;
  vec3 kD = 1.0 - kS;

  vec3 irradiance = texture(irradiance_map, normal).rgb;
  vec3 diffuse = irradiance * albedo;
  vec3 ambient = kD * diffuse + specular;

  return ambient;
}

void main() {
  vec4 world_pos = texture(g_world_pos, v_uv);
  vec3 normal = texture(g_normal, v_uv).xyz;
  vec4 albedo = texture(g_albedo, v_uv);
  vec3 emissive = texture(g_emissive, v_uv).rgb;
  float ao = texture(ao_map, v_uv).r;
  vec3 diffuse = albedo.rgb;
  float roughness = albedo.a;
  float metallic = world_pos.w;

  color = vec4(vec3(0.0f), 1.0f);
  vec3 F0 = vec3(0.04);
  F0 = mix(F0, albedo.rgb, metallic);

  color.rgb = emissive;

  vec3 view_dir = normalize(view_pos - world_pos.xyz);
  vec3 light_dir = normalize(-light_direction);

  vec3 ambient = indirect_lighting(normal, view_dir, F0, roughness, albedo.rgb);
  color.rgb += ambient * ao;

  // direct lighting
  // TODO: for each light
  float bias = max(0.05 * (1.0 - dot(normal, light_dir)), 0.005);
  float shadow = calculate_shadow(world_pos.xyz, bias);

  if (shadow > 0.0) {
    return;
  }

  vec3 Lo = vec3(0.0);
  vec3 radiance  = vec3(1.0);
  vec3 halfway = normalize(view_dir + light_dir);

  float NDF = DistributionGGX(normal, halfway, roughness);
  vec3 F = fresnelSchlick(max(dot(halfway, view_dir), 0.0), F0);
  float G = GeometrySmith(normal, halfway, light_dir, roughness);
  vec3 numerator = NDF * G * F;
  float denominator = 4.0 * max(dot(normal, view_dir), 0.0) * max(dot(normal, light_dir), 0.0);
  vec3 specular = numerator / max(denominator, 0.001);
  vec3 kS = F;
  vec3 kD = vec3(1.0) - kS;
  kD *= 1.0 - metallic;

  float NdotL = max(dot(normal, light_dir), 0.0);
  Lo += (kD * albedo.rgb / PI + specular) * radiance * NdotL;

  color.rgb += Lo;

  float brightness = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
  if (brightness > 1.0) {
    bright_color = vec4(color.rgb, 1.0);
  } else {
    bright_color = vec4(0.0, 0.0, 0.0, 1.0);
  }
}
  #pragma sokol @end

  #pragma sokol @program shading shading_vs shading_fs