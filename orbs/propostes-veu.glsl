precision highp float;

// Canvas explorations only. No microphone is connected.
// Production: drive u_level with a noise-gated, smoothed RMS envelope,
// set u_demo to 0, and use u_motion = 0 for Reduce Motion.

/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Disseny (0–9)
 * @default 0
 * @range 0, 9
 */
uniform float u_variant;
/**
 * @label Volum de veu
 * @default 0.5
 * @range 0, 1
 */
uniform float u_level;
/**
 * @label Demostració de volum (sense micròfon)
 * @default 1
 * @range 0, 1
 */
uniform float u_demo;
/**
 * @label Moviment (0 = només llum)
 * @default 1
 * @range 0, 1
 */
uniform float u_motion;
/**
 * @label Fons
 * @color
 * @default #FAFAFA
 */
uniform vec3 u_background;

const float PI = 3.14159265359;
const vec3 ORANGE = vec3(1.0, 0.41961, 0.0);
const vec3 DEEP = vec3(1.0, 0.29020, 0.07059);
const vec3 AMBER = vec3(1.0, 0.76078, 0.0);
const vec3 PEACH = vec3(1.0, 0.69804, 0.47843);
const vec3 CREAM = vec3(1.0, 0.89020, 0.78431);

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.,0.)), f.x),
             mix(hash(i + vec2(0.,1.)), hash(i + vec2(1.,1.)), f.x), f.y);
}
float fbm(vec2 p) {
  float s = 0., a = 0.5;
  for (int i = 0; i < 4; i++) {
    s += a * noise(p);
    p = mat2(1.62,1.18,-1.18,1.62) * p + 9.2;
    a *= 0.5;
  }
  return s;
}
float disc(float d, float softness) { return 1.0 - smoothstep(-softness, softness, d); }
float line(float d, float width) { return exp(-d*d/(width*width)); }
vec3 spectrum(float t) {
  t = clamp(t, 0.0, 1.0);
  return t < 0.5 ? mix(DEEP, ORANGE, t*2.0) : mix(ORANGE, AMBER, t*2.0-1.0);
}
float fluid(vec2 p, float t, float amp) {
  float a = atan(p.y,p.x);
  float r = 0.655 + amp * (0.055*sin(3.0*a+t) + 0.035*cos(2.0*a-0.7*t));
  return length(p)-r;
}

void main() {
  vec2 q = (gl_FragCoord.xy - 0.5*u_resolution) / (0.5*u_resolution.y);
  float demo = 0.46 + 0.27*sin(u_time*1.05) + 0.11*sin(u_time*2.1+0.6);
  float v = mix(clamp(u_level,0.0,1.0),clamp(demo,0.0,1.0),u_demo);
  float m = v*u_motion;
  float t = u_time*0.26*u_motion;
  float r = length(q), a = atan(q.y,q.x);
  float grain = hash(floor(gl_FragCoord.xy)) - 0.5;
  vec3 bg = u_background;
  vec3 col = bg;

  if (u_variant < 0.5) {
    float size = 0.52 + 0.105*m;
    float halo = exp(-r*r/0.40) * (0.12+0.09*v);
    col = mix(col,PEACH,halo);
    float body = disc(r-size,0.145);
    float light = exp(-dot(q-vec2(-0.16,0.23),q-vec2(-0.16,0.23))/0.10);
    vec3 pigment = mix(ORANGE,DEEP,clamp(-q.y,0.,1.)*0.55);
    pigment = mix(pigment,AMBER,light*0.72);
    pigment = mix(pigment,CREAM,light*0.43);
    col = mix(col,pigment,body*(0.87+0.09*v));
  } else if (u_variant < 1.5) {
    float radius = 0.61+0.045*m;
    vec2 p = q/radius;
    float d = length(p);
    float z = sqrt(max(0.,1.-d*d));
    vec3 n = normalize(vec3(p,z));
    vec3 L = normalize(vec3(-0.5,0.66,0.7));
    float lit = clamp(dot(n,L),0.,1.);
    vec3 pigment = spectrum(0.13+lit*0.82);
    float shine = pow(max(dot(reflect(-L,n),vec3(0.,0.,1.)),0.),18.);
    pigment = mix(pigment,CREAM,shine*0.85);
    pigment = mix(pigment,PEACH,pow(1.-z,5.)*0.8);
    col = mix(col,PEACH,exp(-r*r/0.43)*0.12);
    col = mix(col,pigment,disc(r-radius,0.007));
  } else if (u_variant < 2.5) {
    float wave = (0.008+0.025*m)*sin(5.*a+t*1.4) + 0.018*m*sin(3.*a-t);
    float d = r-(0.63+0.045*m+wave);
    vec3 pigment = spectrum(0.55+0.4*sin(a+0.2));
    col = mix(col,PEACH,line(d,0.06)*(0.19+0.13*v));
    col = mix(col,CREAM,disc(d,0.008)*0.11);
    col = mix(col,pigment,line(d,0.009+0.006*v)*0.94);
    col = mix(col,AMBER,line(d+0.032+0.009*sin(a*4.-t),0.003)*0.40);
    col = mix(col,ORANGE,line(d-0.020,0.002)*0.17);
  } else if (u_variant < 3.5) {
    float spread = 0.92+0.11*m;
    col = mix(col,AMBER,disc(r-0.79*spread,0.013)*0.12);
    col = mix(col,PEACH,disc(length(q-vec2(-0.027,0.018))-0.64*spread,0.009)*0.30);
    col = mix(col,AMBER,disc(length(q-vec2(0.018,-0.009))-0.49*spread,0.006)*0.39);
    float d = length(q-vec2(0.025,0.025))-0.335;
    vec3 pigment = spectrum(0.62+q.y*0.8);
    col = mix(col,pigment,disc(d,0.01));
    col = mix(col,ORANGE,line(r-0.64*spread,0.002)*0.19);
  } else if (u_variant < 4.5) {
    vec2 p = q / (0.94+0.045*m);
    float d = fluid(p,t,0.55+1.2*m);
    float h = sqrt(clamp(-d*2.4,0.,1.));
    float e = 0.003;
    vec2 grad = vec2(fluid(p+vec2(e,0.),t,0.55+1.2*m)-fluid(p-vec2(e,0.),t,0.55+1.2*m),
                     fluid(p+vec2(0.,e),t,0.55+1.2*m)-fluid(p-vec2(0.,e),t,0.55+1.2*m))/(2.*e);
    vec3 n = normalize(vec3(grad*(1.-h),h));
    vec3 L = normalize(vec3(-0.5,0.7,0.7));
    float lit = max(dot(n,L),0.);
    vec3 pigment = spectrum(0.12+lit*0.86);
    pigment = mix(pigment,CREAM,pow(max(dot(reflect(-L,n),vec3(0.,0.,1.)),0.),28.)*0.92);
    pigment = mix(pigment,PEACH,line(d+0.027,0.02)*0.55);
    col = mix(col,PEACH,exp(-max(d,0.)*24.)*0.13);
    col = mix(col,pigment,disc(d,0.006));
  } else if (u_variant < 5.5) {
    for (int i=0; i<9; i++) {
      float f = float(i)/8.;
      float angle = -0.62 + f*1.28;
      vec2 p = mat2(cos(angle),-sin(angle),sin(angle),cos(angle))*q;
      float tension = 0.43+0.16*m;
      p.x /= tension + 0.10*sin(f*PI);
      p.y /= 0.71+0.035*sin(f*PI+t)*m;
      float d = length(p)-1.0;
      float wave = 0.015*m*sin(atan(p.y,p.x)*3.+f*5.+t);
      float stroke = line(d+wave,0.0065+0.003*f);
      col = mix(col,spectrum(0.24+0.72*f),stroke*(0.40+0.40*v));
    }
  } else if (u_variant < 6.5) {
    float radius = 0.59+0.085*m;
    float body = disc(r-radius,0.13);
    float cells = noise(floor(q*15.)*0.31 + vec2(t*0.3,0.));
    vec3 pigment = spectrum(0.33+0.59*cells+q.y*0.15);
    float fleck = hash(floor(gl_FragCoord.xy/1.25));
    float density = (0.52+0.34*v)*body;
    float dots = smoothstep(1.-density-0.09,1.-density+0.09,fleck);
    col = mix(col,PEACH,body*0.17);
    col = mix(col,pigment,dots*body);
    col = mix(col,ORANGE,body*0.11);
  } else if (u_variant < 7.5) {
    float sector = floor((a+PI)/(2.*PI)*120.);
    float seed = hash(vec2(sector,6.));
    float inner = 0.31+0.04*sin(a*3.+t)*m;
    float outer = 0.62 + 0.14*m + 0.055*seed;
    float radial = smoothstep(inner,inner+0.04,r)*(1.-smoothstep(outer-0.08,outer,r));
    float rays = pow(0.5+0.5*cos(a*120.),8.);
    vec3 pigment = spectrum(clamp((r-inner)/(outer-inner)*0.9+0.05,0.,1.));
    col = mix(col,CREAM,radial*0.17);
    col = mix(col,pigment,radial*rays*(0.70+0.18*v));
    col = mix(col,ORANGE,line(r-inner,0.003)*0.36);
  } else if (u_variant < 8.5) {
    float radius = 0.67;
    vec2 p = q*3.;
    float n = fbm(p+vec2(t*0.26,-t*0.19));
    float clouds = fbm(p + (0.8+1.9*m)*vec2(n,fbm(p+3.)));
    float body = disc(r-radius+0.035*(n-0.5),0.08);
    float centerLight = exp(-dot(q-vec2(-0.16,0.08),q-vec2(-0.16,0.08))*5.);
    vec3 pigment = spectrum(clamp(clouds*1.25+centerLight*0.4-0.20,0.,1.));
    pigment = mix(pigment,CREAM,pow(clouds,5.)*0.6);
    pigment += grain*0.065;
    col = mix(col,PEACH,exp(-r*r/0.46)*0.12);
    col = mix(col,pigment,body*(0.86+0.10*v));
  } else {
    float radius = 0.69;
    float outer = disc(r-radius,0.008);
    vec2 offset = vec2(-0.10-0.11*m,0.055+0.035*m);
    float innerR = 0.585;
    float innerD = length(q-offset)-innerR;
    float crescent = outer*(1.-disc(innerD,0.018));
    vec3 pigment = spectrum(0.58+q.y*0.52-q.x*0.16);
    pigment = mix(pigment,CREAM,line(innerD-0.019,0.03)*0.62);
    col = mix(col,PEACH,line(r-radius,0.044)*0.12);
    col = mix(col,pigment,crescent*(0.80+0.18*v));
    col = mix(col,AMBER,line(r-radius,0.004)*(1.-disc(innerD,0.012))*0.6);
  }
  col = mix(bg,col,mix(0.72+0.28*v,1.0,u_motion));
  gl_FragColor = vec4(clamp(col,0.,1.),1.);
}
