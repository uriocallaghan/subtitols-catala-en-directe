precision highp float;

// Orbe "Relleu": l'orbe dibuixat amb corbes de nivell, com un mapa.
// Colors de l'orbe suau: #FF4A12 #FF6B00 #FF9A3D #FFC89A.
// Pensat per a un node de 402 x 300: l'orbe fa uns 250 px i queda centrat.

/** @resolution */
uniform vec2 u_resolution;

/**
 * @label Corbes
 * @default 14
 * @range 6, 30
 */
uniform float u_lines;

/**
 * @label Gruix (px)
 * @default 1.3
 * @range 0.5, 3
 */
uniform float u_width;

/**
 * @label Fase
 * @default 2
 * @range 0, 20
 */
uniform float u_phase;

const float R = 95.0;
const vec3 DEEP = vec3(1.0, 0.290, 0.071);
const vec3 MID = vec3(1.0, 0.420, 0.0);
const vec3 LIGHT = vec3(1.0, 0.604, 0.239);
const vec3 PEACH = vec3(1.0, 0.784, 0.604);

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

vec3 ramp(float t) {
  t = clamp(t, 0.0, 1.0);
  if (t < 0.35) return mix(DEEP, MID, t / 0.35);
  if (t < 0.7) return mix(MID, LIGHT, (t - 0.35) / 0.35);
  return mix(LIGHT, PEACH, (t - 0.7) / 0.3);
}

// Height of a dome: 1 at the top, 0 at the foot, 1.35 R from the centre.
float height(vec2 q) {
  vec2 wobble = vec2(noise(q / 60.0 + u_phase), noise(q / 60.0 + 17.3 - u_phase)) - 0.5;
  vec2 p = q + wobble * 26.0;
  float foot = 1.35 * R;
  vec2 top = vec2(-0.16 * R, 0.18 * R);
  p -= top * (1.0 - clamp(length(p) / foot, 0.0, 1.0));
  float d = length(p) / foot;
  return 1.0 - d * d;
}

void main() {
  float unit = u_resolution.y / 300.0;
  vec2 q = (gl_FragCoord.xy - 0.5 * u_resolution) / unit;
  float px = 1.0 / unit;

  float h = height(q);
  float hx = height(q + vec2(px, 0.0));
  float hy = height(q + vec2(0.0, px));
  float slope = max(length(vec2(hx - h, hy - h)) / px, 1e-5);

  float level = h * u_lines;
  float k = fract(level);
  float gap = min(k, 1.0 - k) / (u_lines * slope);
  float line = 1.0 - smoothstep(0.5 * u_width - 0.5 * px, 0.5 * u_width + 0.5 * px, gap);
  float nearest = floor(level + 0.5) / u_lines;
  line *= step(0.0, nearest) * step(nearest, 1.0 - 0.5 / u_lines);

  float band = floor(level) / u_lines;
  float fillA = h > 0.0 ? 0.04 + 0.3 * band * band : 0.0;
  vec3 fillC = ramp(1.0 - 0.45 * band);

  vec3 lineC = ramp(1.0 - nearest);
  float lineA = line * (0.35 + 0.65 * smoothstep(0.0, 0.5, nearest));

  vec3 color = lineC * lineA + fillC * fillA * (1.0 - lineA);
  float alpha = lineA + fillA * (1.0 - lineA);
  gl_FragColor = vec4(color, alpha);
}
