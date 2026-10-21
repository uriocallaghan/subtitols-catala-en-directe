precision highp float;

// Orbe "Marbre": una esfera on els tons es barregen en remolí.
// Colors de l'orbe suau: #FF4A12 #FF6B00 #FF9A3D #FFC89A #FFE3C8 #FFF1E6.
// Pensat per a un node de 402 x 300: l'orbe fa 190 px i queda centrat.

/** @resolution */
uniform vec2 u_resolution;

/**
 * @label Remolí
 * @default 1
 * @range 0, 2
 */
uniform float u_swirl;

/**
 * @label Fase
 * @default 4
 * @range 0, 20
 */
uniform float u_phase;

const float R = 95.0;
const vec3 DEEP = vec3(1.0, 0.290, 0.071);
const vec3 MID = vec3(1.0, 0.420, 0.0);
const vec3 LIGHT = vec3(1.0, 0.604, 0.239);
const vec3 APRICOT = vec3(1.0, 0.698, 0.478);
const vec3 PEACH = vec3(1.0, 0.784, 0.604);
const vec3 CREAM = vec3(1.0, 0.890, 0.784);
const vec3 WARM = vec3(1.0, 0.945, 0.902);

float hash(vec2 p) {
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

vec3 marble(float t) {
  t = clamp(t, 0.0, 1.0);
  if (t < 0.4) return mix(DEEP, MID, t / 0.4);
  if (t < 0.7) return mix(MID, LIGHT, (t - 0.4) / 0.3);
  if (t < 0.88) return mix(LIGHT, PEACH, (t - 0.7) / 0.18);
  return mix(PEACH, CREAM, (t - 0.88) / 0.12);
}

void main() {
  float unit = u_resolution.y / 300.0;
  vec2 q = (gl_FragCoord.xy - 0.5 * u_resolution) / unit;
  float px = 1.0 / unit;
  float r = length(q);
  float d = r / R;

  float body = 1.0 - smoothstep(R - 0.8 * px, R + 0.8 * px, r);
  vec3 n = vec3(q / R, sqrt(max(0.0, 1.0 - d * d)));

  vec2 p = (q / R) / (0.35 + 0.65 * n.z) * 0.8 + u_phase * 0.13;
  vec2 w1 = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
  vec2 w2 = vec2(fbm(p + 2.8 * u_swirl * w1 + vec2(1.7, 9.2)),
                 fbm(p + 2.8 * u_swirl * w1 + vec2(8.3, 2.8)));
  float f = fbm(p + 2.8 * u_swirl * w2);
  vec3 color = marble(smoothstep(0.3, 0.75, f));

  vec3 L = normalize(vec3(-0.5, 0.6, 0.62));
  float diffuse = clamp(dot(n, L), 0.0, 1.0);
  color = mix(DEEP, color, 0.5 + 0.5 * diffuse);
  float spec = pow(clamp(dot(reflect(-L, n), vec3(0.0, 0.0, 1.0)), 0.0, 1.0), 22.0);
  color = mix(color, WARM, spec * 0.85);
  color = mix(color, APRICOT, pow(1.0 - n.z, 4.0) * 0.45);

  float haloA = 0.42 * (1.0 - smoothstep(0.95, 1.55, d)) * (1.0 - body);
  vec3 premul = color * body + PEACH * haloA;
  gl_FragColor = vec4(premul, body + haloA);
}
