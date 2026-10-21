precision highp float;

// Orbe "Semitò": una esfera feta de punts d'impremta.
// Colors de l'orbe suau: #FF4A12 #FF6B00 #FF9A3D #FFC89A.
// Pensat per a un node de 402 x 300: l'orbe fa 190 px i queda centrat.

/** @resolution */
uniform vec2 u_resolution;

/**
 * @label Mida de la trama (px)
 * @default 6.5
 * @range 4, 24
 */
uniform float u_cell;

/**
 * @label Angle de la trama (graus)
 * @default 45
 * @range 0, 90
 */
uniform float u_angle;

const float R = 95.0;
const vec3 DEEP = vec3(1.0, 0.290, 0.071);
const vec3 MID = vec3(1.0, 0.420, 0.0);
const vec3 LIGHT = vec3(1.0, 0.604, 0.239);
const vec3 PEACH = vec3(1.0, 0.784, 0.604);

vec3 ramp(float t) {
  t = clamp(t, 0.0, 1.0);
  if (t < 0.35) return mix(DEEP, MID, t / 0.35);
  if (t < 0.7) return mix(MID, LIGHT, (t - 0.35) / 0.35);
  return mix(LIGHT, PEACH, (t - 0.7) / 0.3);
}

// Ink (0..1) and colour of the dot whose centre is at c.
vec4 dotAt(vec2 c) {
  float d = length(c) / R;
  if (d < 1.0) {
    vec3 n = vec3(c / R, sqrt(1.0 - d * d));
    float lit = clamp(dot(n, normalize(vec3(-0.5, 0.6, 0.62))), 0.0, 1.0);
    float ink = mix(1.0, 0.26, pow(lit, 1.5));
    ink *= mix(0.45, 1.0, smoothstep(1.0, 0.86, d));
    return vec4(ramp(lit * 0.9), ink);
  }
  float halo = (1.0 - smoothstep(1.0, 1.5, d)) * 0.09;
  return vec4(PEACH, halo);
}

void main() {
  float unit = u_resolution.y / 300.0;
  vec2 q = (gl_FragCoord.xy - 0.5 * u_resolution) / unit;
  float px = 1.0 / unit;

  float a = radians(u_angle);
  mat2 toGrid = mat2(cos(a), -sin(a), sin(a), cos(a));
  vec2 g = toGrid * q;
  vec2 base = floor(g / u_cell);

  float alpha = 0.0;
  vec3 color = vec3(0.0);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 centre = (base + vec2(float(i), float(j)) + 0.5) * u_cell;
      vec4 dotInk = dotAt(centre * toGrid);
      float radius = 0.5 * u_cell * sqrt(dotInk.a) * 1.3;
      float cover = 1.0 - smoothstep(radius - 0.6 * px, radius + 0.6 * px, length(g - centre));
      if (cover > alpha) {
        alpha = cover;
        color = dotInk.rgb;
      }
    }
  }
  gl_FragColor = vec4(color * alpha, alpha);
}
