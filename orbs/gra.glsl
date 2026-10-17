precision highp float;

// Orbe "Gra": l'orbe suau, fet de gra de pel·lícula.
// Colors de l'orbe suau: #FF4A12 #FF6B00 #FF9A3D #FFC89A #FFE3C8.
// Pensat per a un node de 402 x 300: l'orbe fa 190 px i queda centrat.

/** @resolution */
uniform vec2 u_resolution;

/**
 * @label Mida del gra (px)
 * @default 1.1
 * @range 0.6, 4
 */
uniform float u_grain;

/**
 * @label Llavor
 * @default 3
 * @range 0, 20
 */
uniform float u_seed;

const float R = 95.0;
const vec3 DEEP = vec3(1.0, 0.290, 0.071);
const vec3 MID = vec3(1.0, 0.420, 0.0);
const vec3 LIGHT = vec3(1.0, 0.604, 0.239);
const vec3 PEACH = vec3(1.0, 0.784, 0.604);
const vec3 CREAM = vec3(1.0, 0.890, 0.784);

float hash(vec2 p) {
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

vec3 ramp(float t) {
  t = clamp(t, 0.0, 1.0);
  if (t < 0.35) return mix(DEEP, MID, t / 0.35);
  if (t < 0.7) return mix(MID, LIGHT, (t - 0.35) / 0.35);
  return mix(LIGHT, PEACH, (t - 0.7) / 0.3);
}

void main() {
  float unit = u_resolution.y / 300.0;
  vec2 q = (gl_FragCoord.xy - 0.5 * u_resolution) / unit;

  vec2 cell = floor(q / u_grain) + u_seed * 37.0;
  float n1 = hash(cell);
  float n2 = hash(cell + 91.7);
  float n3 = hash(cell - 47.3);

  float d = length(q) / R;
  float density = pow(1.0 - smoothstep(0.5, 1.5, d), 1.6);
  float ink = step(n1, density);

  vec2 warmest = vec2(0.0, -0.24 * R);
  float t = length(q - warmest) / (1.3 * R) + (n2 - 0.5) * 0.16;
  vec3 color = ramp(t);

  vec2 light = vec2(-0.26 * R, 0.3 * R);
  float glow = 1.0 - smoothstep(0.0, 0.62 * R, length((q - light) * vec2(1.0, 1.18)));
  color = mix(color, CREAM, step(n3, glow * 0.85));

  gl_FragColor = vec4(color * ink, ink);
}
