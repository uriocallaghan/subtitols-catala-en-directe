precision highp float;

// Voice-orb design studies. Demo envelope, not live audio.
// A real implementation supplies smoothed, noise-gated RMS through u_level.
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Estudi (0–9)
 * @default 0
 * @range 0, 9
 */
uniform float u_variant;
/**
 * @label Volum
 * @default 0.5
 * @range 0, 1
 */
uniform float u_level;
/**
 * @label Volum simulat
 * @default 1
 * @range 0, 1
 */
uniform float u_demo;
/**
 * @label Moviment (0 = fosa de llum)
 * @default 1
 * @range 0, 1
 */
uniform float u_motion;
/**
 * @label Fase de composició
 * @default 0
 * @range 0, 10
 */
uniform float u_phase;
/**
 * @label Fons
 * @color
 * @default #FAFAFA
 */
uniform vec3 u_background;

const vec3 ORANGE = vec3(1.0,0.4196,0.0);
const vec3 CORAL = vec3(1.0,0.345,0.20);
const vec3 APRICOT = vec3(1.0,0.665,0.415);
const vec3 CREAM = vec3(1.0,0.881,0.725);
const vec3 GOLD = vec3(1.0,0.665,0.155);
const vec3 RUST = vec3(0.66,0.17,0.16);
const vec3 PLUM = vec3(0.30,0.16,0.35);

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx)*0.1031);
  p3 += dot(p3,p3.yzx+33.33);
  return fract((p3.x+p3.y)*p3.z);
}
float noise(vec2 p) {
  vec2 i=floor(p),f=fract(p);
  f=f*f*(3.0-2.0*f);
  return mix(mix(hash(i),hash(i+vec2(1.,0.)),f.x),
             mix(hash(i+vec2(0.,1.)),hash(i+vec2(1.,1.)),f.x),f.y);
}
float field(vec2 p) {
  float n=0.,s=0.57;
  for(int i=0;i<3;i++) {
    n+=s*noise(p);
    p=mat2(1.61,1.21,-1.21,1.61)*p+4.7;
    s*=0.43;
  }
  return n;
}
float gauss(float d,float s) { return exp(-d*d/(s*s)); }
float spot(vec2 p,vec2 c,vec2 s) { vec2 d=(p-c)/s;return exp(-dot(d,d)); }
float inside(float d,float soft) { return 1.-smoothstep(-soft,soft,d); }
vec3 expose(vec3 e) { return vec3(1.)-exp(-max(e,vec3(0.))); }
float expose1(float e) { return 1.-exp(-max(e,0.)); }

void main() {
  vec2 q=(gl_FragCoord.xy-0.5*u_resolution)/(0.5*u_resolution.y);
  float demo=0.46+0.24*sin(u_time*0.91)+0.10*sin(u_time*1.82+0.4);
  float v=mix(u_level,demo,u_demo);
  float m=v*u_motion;
  float t=u_time*0.13*u_motion+u_phase;
  float breathing=1.+0.013*m;
  vec2 p=q/(0.73*breathing);
  float r=length(p);
  float a=atan(p.y,p.x);
  float n=field(p*1.8+vec2(t*0.22,-t*0.13));
  float grain=hash(floor(gl_FragCoord.xy))-0.5;
  vec3 bg=u_background;
  vec3 col=bg;
  vec3 pigment=ORANGE;
  float mask=inside(r-1.,0.008);

  if(u_variant<0.5) {
    // Matte satin: a deep fold, not a shaded plastic sphere.
    float fold=p.y+0.30*p.x+0.19*sin(2.7*p.x+0.45+t*0.22)*(0.7+0.45*m);
    pigment=mix(CORAL,APRICOT,smoothstep(-0.22,1.3,p.y+0.27*p.x));
    pigment=mix(pigment,ORANGE,spot(p,vec2(0.45,0.22),vec2(0.65,0.8))*0.58);
    pigment=mix(pigment,RUST,1.-smoothstep(-0.58,-0.03,fold));
    pigment=mix(pigment,PLUM,(1.-smoothstep(-0.82,-0.30,fold))*0.84);
    pigment=mix(pigment,CREAM,gauss(fold+0.075,0.12)*0.72);
    pigment=mix(pigment,APRICOT,gauss(fold-0.13,0.22)*0.43);
    pigment+=grain*0.026;
    col=mix(bg,pigment,mask);
  } else if(u_variant<1.5) {
    // Broad, flowing aurora. Orange remains the largest colour field.
    float wave=p.y-0.25*sin(p.x*2.8+0.4+t*0.2)*(0.75+0.4*m)+0.30*p.x+0.14;
    pigment=mix(ORANGE,CORAL,smoothstep(-0.6,0.5,p.x-p.y));
    pigment=mix(pigment,APRICOT,smoothstep(-0.18,0.95,wave)*0.80);
    pigment=mix(pigment,CREAM,gauss(wave-0.24,0.28)*0.76);
    pigment=mix(pigment,RUST,(1.-smoothstep(-0.72,-0.03,wave))*0.80);
    pigment=mix(pigment,PLUM,spot(p,vec2(0.72,-0.62),vec2(0.73,0.47))*0.76);
    pigment+=grain*0.023;
    col=mix(bg,pigment,inside(r-1.,0.012));
  } else if(u_variant<2.5) {
    // Soft-focus chromatic volume with a narrow plum shadow.
    vec2 drift=vec2(0.045*sin(t),0.025*cos(t));
    pigment=mix(ORANGE,CORAL,spot(p,vec2(0.18,0.12)+drift,vec2(0.72,0.9))*0.6);
    pigment=mix(pigment,GOLD,spot(p,vec2(-0.60,-0.50),vec2(0.65,0.65))*0.91);
    float chroma=spot(p,vec2(0.73,-0.24)+drift,vec2(0.57,0.95));
    pigment=mix(pigment,vec3(0.97,0.22,0.26),chroma*0.9);
    pigment=mix(pigment,vec3(0.43,0.13,0.73),smoothstep(0.25,0.88,chroma)*0.94);
    pigment=mix(pigment,vec3(0.61,0.20,0.73),spot(p,vec2(-0.94,0.03),vec2(0.22,0.47))*0.68);
    pigment=mix(pigment,APRICOT,spot(p,vec2(-0.20,0.86),vec2(0.85,0.42))*0.78);
    col=mix(bg,APRICOT,gauss(r-0.94,0.24)*0.12);
    col=mix(col,pigment+grain*0.009,inside(r-0.97,0.10+0.015*m));
  } else if(u_variant<3.5) {
    // Printed pigment: broad dunes, fine continuous grain.
    float dune=p.y+0.24*p.x+0.16*sin(p.x*2.6+t*0.18)+(n-0.5)*0.24;
    pigment=mix(CORAL,ORANGE,smoothstep(-0.3,0.7,p.x));
    pigment=mix(pigment,APRICOT,gauss(dune-0.56,0.51)*0.94);
    pigment=mix(pigment,RUST,gauss(dune+0.02,0.28)*0.66);
    pigment=mix(pigment,CREAM,gauss(dune+0.44+0.05*m,0.24)*0.88);
    pigment=mix(pigment,GOLD,gauss(dune+0.77,0.22)*0.59);
    pigment+=grain*0.078;
    col=mix(bg,pigment,inside(r-1.,0.007));
  } else if(u_variant<4.5) {
    // Organic, smoky volume; no points, rings or sharp lobes.
    float deform=0.092*sin(a*3.+t*0.28)+0.043*sin(a*4.-t*0.21);
    float d=r-(0.93+deform*(0.65+0.5*m));
    pigment=mix(ORANGE,RUST,spot(p,vec2(-0.40,-0.30),vec2(0.82,0.60))*0.85);
    pigment=mix(pigment,PLUM,spot(p,vec2(-0.54,-0.35),vec2(0.49,0.52))*0.63);
    pigment=mix(pigment,CORAL,spot(p,vec2(0.22,0.25),vec2(0.80,0.63))*0.48);
    pigment=mix(pigment,GOLD,spot(p,vec2(0.43,-0.46),vec2(0.65,0.46))*0.82);
    pigment=mix(pigment,APRICOT,spot(p,vec2(-0.20,0.70),vec2(0.75,0.54))*0.71);
    pigment+=(n-0.5)*0.045+grain*0.048;
    col=mix(bg,pigment,inside(d,0.18));
  } else {
    // Night family. The background picks how the light is drawn: added to a
    // dark ground, or on a light ground laid down as orange pigment over a
    // pale #FFF1E6 body. Pigment density walks the project ramp (#FFE3C8,
    // #FFB27A, #FF6B00) and stops at #FF4A12; the hottest light walks back
    // down the same ramp toward cream.
    float sphere=inside(r-1.,0.018);
    float rim=gauss(r-0.985,0.012);
    float haze=gauss(r-0.98,0.07);
    float le=0.,lw=0.,lh=0.;
    vec3 tint=vec3(0.);
    float body=sphere;
    float density=1.,glint=0.;
    vec3 emission=vec3(1.0,0.27,0.036);
    vec3 warm=vec3(1.0,0.60,0.26);
    vec3 hot=vec3(1.0,0.84,0.63);
    if(u_variant<5.5) {
      // First reference: light crossing a dark translucent membrane.
      float wave=p.y-0.20-0.45*sin(2.5*p.x+0.45+t*0.2)*(0.75+0.3*m);
      float focus=spot(p,vec2(-0.37,0.13),vec2(0.65,0.95));
      float ribbon=gauss(wave,0.06)*focus;
      float plume=gauss(wave+0.11,0.23)*focus;
      float arc=pow(max(0.,-cos(a+0.2)),3.0);
      float returnFold=length((p-vec2(-0.33,-0.26))/vec2(0.43,0.58))-1.;
      float returnLight=gauss(returnFold,0.12)*spot(p,vec2(-0.31,-0.32),vec2(0.64,0.64));
      le+=(plume*2.3+returnLight*0.65+0.07*spot(p,vec2(-0.2,0.1),vec2(0.8)))*sphere;
      lw+=(ribbon*2.3+gauss(wave,0.13)*focus*0.9)*sphere;
      lh+=ribbon*ribbon*2.3*sphere;
      lw+=rim*(0.045+2.6*arc);
      le+=haze*(0.04+0.72*arc);
      le+=gauss(r-1.,0.24)*arc*0.18;
    } else if(u_variant<6.5) {
      // Veiled ember, soft layers and a sharp circular silhouette.
      vec2 w=p+vec2(n-0.5,field(p*2.0+4.)-0.5)*0.8;
      float tide=sin(w.y*3.6+w.x*1.3+t*0.22)*0.5+0.5;
      float glow=spot(p,vec2(-0.20,0.14),vec2(1.0,0.83));
      density=0.72;
      glint=pow(tide,2.5)*glow*0.8*sphere;
      le+=(0.30+1.8*glow+1.0*tide)*(0.70+0.30*m)*sphere;
      lw+=pow(tide,5.)*glow*0.84*sphere;
      lh+=spot(p,vec2(-0.50,0.61),vec2(0.45,0.23))*0.58*sphere;
      lw+=rim*0.12;
    } else if(u_variant<7.5) {
      // Refracted silk folds, never a wireframe or a loading spinner.
      float fold=p.y+0.27*p.x-0.28*sin(p.x*2.4+0.4+t*0.18)*(0.7+0.45*m);
      float focus=0.45+0.55*spot(p,vec2(0.10,-0.04),vec2(0.9,0.7));
      float band=gauss(fold+0.06,0.115)*focus;
      float secondary=gauss(fold-0.28,0.17)*spot(p,vec2(-0.45,0.3),vec2(0.7));
      le+=(band*1.95+secondary*0.85+0.08)*sphere;
      lw+=gauss(fold+0.07,0.045)*focus*1.75*sphere;
      lh+=gauss(fold+0.07,0.022)*focus*0.84*sphere;
      lw+=rim*(0.1+0.46*max(0.,sin(a-0.4)));
      le+=haze*0.08;
    } else if(u_variant<8.5) {
      // Dawn in a dark sphere: one luminous horizon, no crescent cutout.
      float horizon=p.y+0.46+0.16*p.x+0.11*sin(p.x*3.+t*0.2);
      float glow=gauss(horizon,0.30+0.06*m);
      le+=glow*1.7*sphere;
      lw+=gauss(horizon+0.02,0.09)*1.25*sphere;
      lh+=gauss(horizon+0.025,0.035)*spot(p,vec2(-0.28,-0.40),vec2(0.9,0.4))*0.80*sphere;
      tint+=vec3(0.2,0.05,0.08)*sphere*(1.-glow)*0.32;
      lw+=rim*(0.10+0.65*pow(max(0.,-sin(a)),3.));
      le+=haze*pow(max(0.,-sin(a)),3.)*0.15;
    } else {
      // Diffuse, warm smoke with quiet internal colour separation.
      float d=r-0.95-(0.03+0.025*m)*sin(a*3.+t*0.17);
      float volume=inside(d,0.15);
      vec2 w=p+0.60*vec2(n,field(p*1.6+5.));
      float curl=sin(w.x*3.0-w.y*2.4+t*0.20)*0.5+0.5;
      body=volume;
      le+=(0.22+1.90*curl)*volume;
      lw+=pow(curl,4.)*0.86*volume;
      lh+=spot(p,vec2(-0.30,0.50),vec2(0.6,0.3))*0.42*volume;
      le+=gauss(d,0.16)*0.11;
    }
    float gain=0.88+0.22*v;
    vec3 lit=bg+(vec3(1.)-bg)*expose((emission*le+warm*lw+hot*lh+tint)*gain);
    float light=(0.42*le+0.62*lw)*gain*density;
    float cream=max(max(expose1(lh*gain)*0.85,smoothstep(1.0,2.2,light)*0.7),glint);
    float ink=1.25*pow(expose1(light),0.8)*(1.-cream);
    pigment=mix(bg,vec3(1.,0.945,0.902),body)*exp(-vec3(0.,1.,2.2)*ink);
    float daylight=smoothstep(0.3,0.7,dot(bg,vec3(0.2126,0.7152,0.0722)));
    col=mix(lit,pigment,daylight);
    col+=grain*0.018*sphere;
  }
  col=mix(bg,col,mix(0.78+0.22*v,1.,u_motion));
  gl_FragColor=vec4(clamp(col,0.,1.),1.);
}
