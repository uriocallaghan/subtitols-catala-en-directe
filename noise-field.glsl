precision highp float;

/** @resolution */
uniform vec2 u_resolution;

/**
 * @label Phase
 * @range 0, 20
 * @default 3.2
 */
uniform float u_phase;

/**
 * @label Cell size (px per 410 px width)
 * @range 20, 140
 * @default 70
 */
uniform float u_cell;

float hash(vec2 p, float seed) {
  p = p + seed * 17.13;
  vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

float valueNoise(vec2 p, float seed) {
  vec2 c = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float top = mix(hash(c, seed), hash(c + vec2(1.0, 0.0), seed), f.x);
  float bottom = mix(hash(c + vec2(0.0, 1.0), seed), hash(c + vec2(1.0, 1.0), seed), f.x);
  return mix(top, bottom, f.y);
}

void main() {
  vec2 frag = vec2(gl_FragCoord.x, u_resolution.y - gl_FragCoord.y);
  float cellSize = max(1.0, u_resolution.x * (u_cell / 410.0));
  vec2 cell = floor(frag / cellSize);

  float broad = valueNoise(cell * 0.19 + vec2(17.3, -8.1) + u_phase * vec2(0.90, 0.35), 1.0);
  float detail = valueNoise(cell * 0.43 + vec2(-5.2, 11.7) + u_phase * vec2(-1.40, 0.60), 2.0);
  float tone = broad * 0.74 + detail * 0.26;
  float greenByte = clamp(128.655 + (tone - 0.5) * 195.0, 48.0, 194.0);

  vec2 g = mod(floor(frag), 64.0);
  float redDark = hash(g, 3.0) < 0.5 ? hash(g, 4.0) * 10.0 : 0.0;
  float greenDark = hash(g, 5.0) * 27.0;
  float greenLight = hash(g, 6.0) * 16.0;
  float blueLight = hash(g, 7.0) < 0.5 ? hash(g, 8.0) * 10.0 : 0.0;

  vec3 color = vec3(1.0, greenByte / 255.0, 0.0);
  color *= vec3(1.0 - redDark / 255.0, 1.0 - greenDark / 255.0, 1.0);
  color += vec3(0.0, greenLight / 255.0, blueLight / 255.0);
  gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
