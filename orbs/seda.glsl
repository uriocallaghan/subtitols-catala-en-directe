precision highp float;

// Seda in the app's own colours, with controls. The satin fold of study
// V2 / 01 Seda (orbs/atmosferics-v2.glsl, variant 0). The four palette colours
// default to the colour of ProceduralNoise.metal (red 255, blue 0, a green
// byte between 48 and 194), over the part of that ramp the running app shows:
// #FF6400 to #FFC200 on a screenshot of it, 2026-09-26. Any mix of them stays
// on the ramp, and iridescence and dispersion move through the palette rather
// than the rainbow, so only the colour pickers can bring in another hue.
// The animation loops seamlessly every u_duration seconds: every moving term
// turns a whole number of times per cycle. pen.dev advances u_time only while
// the node is selected and renders exports and screenshots at u_time 0, so
// u_phase picks the moment those show.
// The grain is the app's, but fixed to the silk rather than the screen, so it
// breathes and wobbles with the orb and grains its soft edge too.
// Demo envelope, not live audio. A real implementation sets u_demo = 0 and
// supplies a gated, smoothed RMS through u_level.
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Durada del cicle (s)
 * @default 60
 * @range 10, 600
 */
uniform float u_duration;
/**
 * @label Moviment (0 = fosa de llum)
 * @default 1
 * @range 0, 1
 */
uniform float u_motion;
/**
 * @label Fase de composició (0–1 = un cicle)
 * @default 0
 * @range 0, 1
 */
uniform float u_phase;
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
 * @label Reacció a la veu
 * @default 1
 * @range 0, 2
 */
uniform float u_react;
/**
 * @label Mida
 * @default 1
 * @range 0.3, 1.3
 */
uniform float u_size;
/**
 * @label Forma (0 rodona · 1 quadrada)
 * @default 0
 * @range 0, 1
 */
uniform float u_square;
/**
 * @label Vora (0 nítida · 1 difuminada)
 * @default 0
 * @range 0, 1
 */
uniform float u_edge;
/**
 * @label Deformació
 * @default 0.2
 * @range 0, 1
 */
uniform float u_deform;
/**
 * @label Detall de la deformació
 * @default 0.3
 * @range 0, 1
 */
uniform float u_deformDetail;
/**
 * @label Plec
 * @default 1
 * @range 0, 2
 */
uniform float u_fold;
/**
 * @label Angle del plec (°)
 * @default 0
 * @range -90, 90
 */
uniform float u_foldAngle;
/**
 * @label Brillantor de la cresta
 * @default 1
 * @range 0, 1.2
 */
uniform float u_crest;
/**
 * @label Amplada de la cresta
 * @default 1
 * @range 0.3, 3
 */
uniform float u_crestWidth;
/**
 * @label Turbulència
 * @default 0.25
 * @range 0, 1
 */
uniform float u_turbulence;
/**
 * @label Escala de la turbulència
 * @default 1
 * @range 0.3, 3
 */
uniform float u_turbulenceScale;
/**
 * @label Color 1 · ombra
 * @color
 * @default #FF6400
 */
uniform vec3 u_color1;
/**
 * @label Color 2 · cos
 * @color
 * @default #FF7800
 */
uniform vec3 u_color2;
/**
 * @label Color 3 · llum
 * @color
 * @default #FFA400
 */
uniform vec3 u_color3;
/**
 * @label Color 4 · cresta
 * @color
 * @default #FFC200
 */
uniform vec3 u_color4;
/**
 * @label Fons
 * @color
 * @default #FAFAFA
 */
uniform vec3 u_background;
/**
 * @label Equilibri de color (− ombra · + llum)
 * @default 0
 * @range -1, 1
 */
uniform float u_balance;
/**
 * @label Contrast
 * @default 1
 * @range 0, 2
 */
uniform float u_contrast;
/**
 * @label Desplaçament de paleta
 * @default 0
 * @range -1, 1
 */
uniform float u_shift;
/**
 * @label Moviment de la paleta
 * @default 0
 * @range 0, 1
 */
uniform float u_shiftMotion;
/**
 * @label Iridescència
 * @default 0
 * @range 0, 1
 */
uniform float u_iridescence;
/**
 * @label Dispersió
 * @default 0
 * @range 0, 1
 */
uniform float u_dispersion;
/**
 * @label Gra (1 = el de l'app)
 * @default 1
 * @range 0, 3
 */
uniform float u_grain;
/**
 * @label Mida del gra (px)
 * @default 1
 * @range 0.5, 4
 */
uniform float u_grainSize;

const float TAU=6.28318531;
// Tones are positions on the palette: Color 1 at 0, 2 at 1/3, 3 at 2/3 and 4
// at 1. With the default colours each lands on the green byte the single-ramp
// Seda used; the V2 colour each one replaces is in brackets.
const float DEEPEST=0.0;     // Color 1, #FF6400 (plum)
const float ORANGE=0.1167;   // #FF6B00, $deco (orange)
const float EMBER=0.1667;    // #FF6E00 (rust)
const float FLAME=0.3333;    // Color 2, #FF7800 (coral)
const float APRICOT=0.6667;  // Color 3, #FFA400 (apricot)
const float AMBER=1.0;       // Color 4, #FFC200 (cream)

float hash(vec2 p) {
  vec3 p3=fract(vec3(p.xyx)*0.1031);
  p3+=dot(p3,p3.yzx+33.33);
  return fract((p3.x+p3.y)*p3.z);
}
float gauss(float d,float s) { return exp(-d*d/(s*s)); }
float spot(vec2 p,vec2 c,vec2 s) { vec2 d=(p-c)/s;return exp(-dot(d,d)); }
// Runs 0 → 1 → 0 over every 2: a tone pushed past either end of the palette
// turns back instead of leaving it.
float bounce(float x) { return 1.-abs(1.-mod(x,2.)); }

vec3 palette(float x) {
  x=clamp(x,0.,1.)*3.;
  vec3 c=mix(u_color1,u_color2,clamp(x,0.,1.));
  c=mix(c,u_color3,clamp(x-1.,0.,1.));
  return mix(c,u_color4,clamp(x-2.,0.,1.));
}

// Simulated voice: slow swells and a quicker flutter.
float voice(float th) {
  return clamp(0.46+0.20*sin(3.*th+0.3)+0.12*sin(7.*th+1.9)
    +0.07*sin(13.*th+4.2)+0.04*sin(29.*th+0.7),0.,1.);
}

// The outline as a multiple of the radius at angle a (x), and its slope (y).
// Lobes of 2, 3, 4, 5 and 7 turn against each other and swell with the voice;
// detail brings in the smaller ones.
vec2 outline(float a,float th,float m) {
  float k=u_deformDetail;
  vec4 e=vec4(0.50*(0.75+0.25*sin(th+1.1)),0.36*(0.75+0.25*sin(2.*th+3.0)),
              0.24*k*(0.7+0.3*sin(3.*th+0.2)),0.16*k);
  float e7=0.10*k*k;
  vec4 ph=vec4(2.*a+th+0.4,3.*a-2.*th+1.7,4.*a+3.*th+4.1,5.*a-4.*th+2.3);
  float ph7=7.*a+5.*th+0.9;
  float amp=u_deform*0.16*(1.+0.5*m);
  float w=dot(e,sin(ph))+e7*sin(ph7);
  float dw=dot(e*vec4(2.,3.,4.,5.),cos(ph))+7.*e7*cos(ph7);
  return vec2(1.+amp*w,amp*dw);
}

// Turbulence: five sine layers of rising frequency, each rotated and each
// bending the coordinates the next one reads, so the silk curls instead of
// rippling. Returns the displacement.
vec2 flow(vec2 p,float th) {
  vec2 x=p;
  float f=1.;
  mat2 r=mat2(1.,0.,0.,1.);
  mat2 turn=mat2(0.8,0.6,-0.6,0.8);
  for(int i=0;i<5;i++) {
    float k=float(i);
    vec2 s=sin((r*x).yx*f+vec2((1.+k)*th+1.7*k,-(1.+k)*th+2.9*k))/f;
    x+=0.55*(s*r);
    r=turn*r;
    f*=1.7;
  }
  return x-p;
}

// The satin fold of V2 / 01 Seda as a palette position (x), and the fold
// itself (y), which the iridescence follows.
vec2 silk(vec2 p,float th,float m) {
  float c=cos(radians(u_foldAngle)),s=sin(radians(u_foldAngle));
  p=mat2(c,s,-s,c)*p;
  p+=u_turbulence*0.45*flow(p*u_turbulenceScale,th)/u_turbulenceScale;
  float fold=p.y+0.30*p.x+u_fold*0.19*sin(2.7*p.x+0.45+th)*(0.7+0.45*m);
  float t=mix(FLAME,APRICOT,smoothstep(-0.22,1.3,p.y+0.27*p.x));
  t=mix(t,ORANGE,spot(p,vec2(0.45,0.22),vec2(0.65,0.8))*0.58);
  t=mix(t,EMBER,1.-smoothstep(-0.58,-0.03,fold));
  t=mix(t,DEEPEST,(1.-smoothstep(-0.82,-0.30,fold))*0.84);
  t=mix(t,AMBER,gauss(fold+0.075,0.12*u_crestWidth)*min(0.88*u_crest,1.));
  t=mix(t,APRICOT,gauss(fold-0.13,0.22*u_crestWidth)*0.43*min(u_crest,1.));
  return vec2(t,fold);
}

// The palette controls on one tone. light < 1 sinks it toward Color 1.
float grade(float t,float fold,float z,float th,float light) {
  t=clamp((t-0.5)*u_contrast+0.5,0.,1.);
  t=pow(t,exp2(-1.6*u_balance));
  // Iridescence: a thin film that thickens toward the rim, read as bands that
  // run along the palette and back. The film drifts two palette lengths, one
  // whole bounce, per cycle.
  float film=(1.-z)*2.4+0.35*sin(3.*fold+2.*th)+th/3.14159265;
  t=mix(t,bounce(t+film),u_iridescence*(0.35+0.65*(1.-z)));
  t=bounce(t+u_shift+u_shiftMotion*0.5*sin(th));
  return t*light;
}

// One look at the orb from q: palette position (x) and coverage (y). blur
// widens the edge, in orb radii.
vec2 orb(vec2 q,float th,float m,float light,float px,float blur) {
  float R=0.73*u_size*(1.+0.013*m);
  vec2 p=q/R;
  vec2 o=outline(atan(p.y,p.x+1e-6),th,m);
  // Superellipse: exponent 2 is the circle, 8 a square with round corners.
  float n=mix(2.,8.,u_square);
  vec2 ap=max(abs(p),vec2(1e-4));
  float rn=pow(pow(ap.x,n)+pow(ap.y,n),1./n);
  float d=(rn-o.x)/sqrt(1.+o.y*o.y/max(rn*rn,0.01));
  float soft=0.9*px/R+u_edge*u_edge*0.55+blur;
  float cover=1.-smoothstep(-soft,soft,d);
  float z=sqrt(max(0.,1.-rn*rn/(o.x*o.x)));
  // The silk is read through the outline, so it stretches with the lobes
  // instead of sliding under them.
  vec2 s=silk(p/o.x,th,m);
  return vec2(grade(s.x,s.y,z,th,light),cover);
}

// Grain cells fixed to the silk: one cell is a device pixel of a 300 pt tall
// frame at 100 % while the orb is at rest, and the cells stretch with the
// lobes and the breathing.
vec2 grainCell(vec2 q,float th,float m) {
  float R=0.73*u_size*(1.+0.013*m);
  vec2 p=q/R;
  vec2 o=outline(atan(p.y,p.x+1e-6),th,m);
  return floor(p/o.x*R*300./u_grainSize);
}

// The app's grain (noiseFragment in ProceduralNoise.metal): per-pixel
// offsets where half the pixels lose up to 10/255 of red, green loses up to
// 27/255 of itself and gains up to 16/255, and half the pixels gain up to
// 10/255 of blue. u_grain scales it (1 is the app's). WebGL 1 has no integer
// hash, so a float hash stands in for hashValue: the same distributions, not
// the same pixels.
vec3 grain(vec3 col,vec2 c) {
  float redDark=hash(c+vec2(0.,1031.))<0.5?hash(c+vec2(0.,2063.))*10.:0.;
  float greenDark=hash(c+vec2(0.,3089.))*27.;
  float greenLight=hash(c+vec2(0.,4111.))*16.;
  float blueLight=hash(c+vec2(0.,5147.))<0.5?hash(c+vec2(0.,6173.))*10.:0.;
  col*=vec3(1.-u_grain*redDark/255.,1.-u_grain*greenDark/255.,1.);
  col+=u_grain*vec3(0.,greenLight,blueLight)/255.;
  return clamp(col,0.,1.);
}

// Grains a partial coverage, strongest at half, so a soft edge dissolves in
// grain like the rest of the orb instead of fading smoothly over it.
float grainEdge(float a,vec2 c) {
  return clamp(a+(hash(c+vec2(0.,7187.))-0.5)*u_grain*a*(1.-a),0.,1.);
}

void main() {
  vec2 q=(gl_FragCoord.xy-0.5*u_resolution)/(0.5*u_resolution.y);
  float px=2./u_resolution.y;
  float cycle=u_time/max(u_duration,1.);
  float th=TAU*fract(cycle*u_motion+u_phase);
  float v=mix(u_level,voice(TAU*fract(cycle+u_phase)),u_demo);
  float m=v*u_motion*u_react;
  // Without motion the voice shows as light: quiet sinks toward Color 1
  // instead of fading into the background, which would tint it pale.
  float light=mix(0.78+0.22*v,1.,u_motion);
  vec2 o=orb(q,th,m,light,px,0.);
  vec3 pigment=palette(o.x);
  vec3 col=u_background;
  vec2 cell=grainCell(q,th,m);
  if(u_dispersion>0.001) {
    // Dispersion: six copies of the orb, from slightly larger and lighter to
    // slightly smaller and deeper, blended where each one covers, so every
    // edge splits into a band that runs along the palette, the way white light
    // leaves a prism. A copy moves a tone only as far as the palette has room
    // on both sides, so flat areas keep their colour. The larger copies also
    // spill past the outline as a soft glow.
    float dd=u_dispersion*0.14,sh=u_dispersion*0.55;
    vec3 sum=vec3(0.),glow=vec3(0.);
    float weight=0.,spill=0.;
    for(int i=0;i<6;i++) {
      float k=(float(i)+0.5)/3.-1.;
      vec2 c=orb(q*(1.-k*dd),th,m,light,px,dd/3.);
      sum+=palette(c.x+k*sh*2.*min(c.x,1.-c.x))*c.y;
      weight+=c.y;
      if(k>0.) {
        glow+=palette(c.x+sh)*c.y;
        spill+=c.y;
      }
    }
    pigment=mix(pigment,sum/max(weight,1e-4),smoothstep(0.,0.05,weight));
    col=mix(col,grain(glow/max(spill,1e-4),cell),grainEdge(spill/3.*0.45,cell));
  }
  col=mix(col,grain(pigment,cell),grainEdge(o.y,cell));
  gl_FragColor=vec4(col,1.);
}
