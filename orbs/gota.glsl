precision highp float;

// Orbe "Gota": una massa líquida que es desdobla.
// Colors de l'orbe suau: #FF4A12 #FF6B00 #FF9A3D #FFB27A #FFC89A #FFF1E6.
// Pensat per a un node de 402 x 300: la gota fa uns 220 px i queda centrada.

/** @resolution */
uniform vec2 u_resolution;

/**
 * @label Fase
 * @default 0.8
 * @range 0, 6.28
 */
uniform float u_phase;

const vec3 DEEP = vec3(1.0, 0.290, 0.071);
const vec3 MID = vec3(1.0, 0.420, 0.0);
const vec3 LIGHT = vec3(1.0, 0.604, 0.239);
const vec3 APRICOT = vec3(1.0, 0.698, 0.478);
const vec3 PEACH = vec3(1.0, 0.784, 0.604);
const vec3 WARM = vec3(1.0, 0.945, 0.902);

vec3 ramp(float t) {
  t = clamp(t, 0.0, 1.0);
  if (t < 0.35) return mix(DEEP, MID, t / 0.35);
  if (t < 0.7) return mix(MID, LIGHT, (t - 0.35) / 0.35);
  return mix(LIGHT, PEACH, (t - 0.7) / 0.3);
}

float smin(float a, float b, float k) {
  float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

// Signed distance to the drop, in px (negative inside).
float drop(vec2 q) {
  vec2 sway = vec2(cos(u_phase), sin(u_phase));
  float d = length(q - vec2(-6.0, -4.0)) - 82.0;
  d = smin(d, length(q - vec2(60.0, 58.0) - 6.0 * sway) - 32.0, 30.0);
  d = smin(d, length(q - vec2(-68.0, -60.0) + 4.0 * sway.yx) - 21.0, 24.0);
  d = smin(d, length(q - vec2(76.0, -42.0)) - 16.0, 22.0);
  d = min(d, length(q - vec2(110.0, 100.0) - 3.0 * sway) - 11.0);
  return d;
}

float height(vec2 q) {
  return 1.0 - exp(-max(-drop(q), 0.0) / 26.0);
}

void main() {
  float unit = u_resolution.y / 300.0;
  vec2 q = (gl_FragCoord.xy - 0.5 * u_resolution) / unit;
  float px = 1.0 / unit;

  float d = drop(q);
  float body = 1.0 - smoothstep(-0.8 * px, 0.8 * px, d);

  float e = 1.5;
  float dx = height(q + vec2(e, 0.0)) - height(q - vec2(e, 0.0));
  float dy = height(q + vec2(0.0, e)) - height(q - vec2(0.0, e));
  vec3 n = normalize(vec3(-dx * 14.0, -dy * 14.0, 1.0));

  vec3 L = normalize(vec3(-0.5, 0.6, 0.62));
  float lit = clamp(dot(n, L), 0.0, 1.0);
  vec3 color = ramp(0.05 + 0.85 * lit + q.y / 520.0);
  float spec = pow(clamp(dot(reflect(-L, n), vec3(0.0, 0.0, 1.0)), 0.0, 1.0), 36.0);
  color = mix(color, WARM, spec * 0.9);

  float glowA = 0.3 * exp(-max(d, 0.0) / 16.0) * (1.0 - body);
  vec3 premul = color * body + APRICOT * glowA;
  gl_FragColor = vec4(premul, body + glowA);
}
