precision highp float;

// Voice orbs, study 3: crisp spheres with a living interior, in the manner of
// the ChatGPT voice orb (a sky of clouds) and the ElevenLabs orb (liquid
// colour, glass, pearl). Project colours only: the oranges #FF4A12 … #FF9A3D,
// amber #FFC200 and the creams #FFB27A … #FFF1E6, mixed only among
// themselves; white appears only as reflected light.
// Demo envelope, not live audio. A real implementation sets u_demo = 0 and
// supplies a gated, smoothed RMS through u_level.
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Orbe (0 Cel · 1 Capvespre · 2 Mel · 3 Ambre · 4 Nacre · 5 Bombolla)
 * @default 0
 * @range 0, 5
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
/**
 * @label Soroll (gra)
 * @default 0
 * @range 0, 1
 */
uniform float u_noise;
/**
 * @label Mida del gra (px)
 * @default 1
 * @range 0.5, 4
 */
uniform float u_grain;

const float PI=3.14159265;
const float TAU=6.28318531;
const vec3 DEEP=vec3(1.0,0.290,0.071);      // #FF4A12
const vec3 ORANGE=vec3(1.0,0.420,0.0);      // #FF6B00
const vec3 TANGERINE=vec3(1.0,0.541,0.239); // #FF8A3D
const vec3 APRICOT=vec3(1.0,0.604,0.239);   // #FF9A3D
const vec3 PEACH=vec3(1.0,0.698,0.478);     // #FFB27A
const vec3 SAND=vec3(1.0,0.784,0.604);      // #FFC89A
const vec3 BLUSH=vec3(1.0,0.851,0.741);     // #FFD9BD
const vec3 CREAM=vec3(1.0,0.890,0.784);     // #FFE3C8
const vec3 SHELL=vec3(1.0,0.945,0.902);     // #FFF1E6
const vec3 AMBER=vec3(1.0,0.761,0.0);       // #FFC200
const vec3 LIGHT=vec3(1.0,0.984,0.969);     // reflected light

float hash12(vec2 p) {
  vec3 p3=fract(vec3(p.xyx)*0.1031);
  p3+=dot(p3,p3.yzx+33.33);
  return fract((p3.x+p3.y)*p3.z);
}
vec2 hash22(vec2 p) {
  vec3 p3=fract(vec3(p.xyx)*vec3(0.1031,0.1030,0.0973));
  p3+=dot(p3,p3.yzx+33.33);
  return fract((p3.xx+p3.yz)*p3.zy)*2.0-1.0;
}
vec3 hash33(vec3 p) {
  p=fract(p*vec3(0.1031,0.1030,0.0973));
  p+=dot(p,p.yxz+33.33);
  return fract((p.xxy+p.yxx)*p.zyx)*2.0-1.0;
}
float noise2(vec2 p) {
  vec2 i=floor(p),f=fract(p);
  vec2 u=f*f*(3.0-2.0*f);
  vec2 e=vec2(1.0,0.0);
  return mix(mix(dot(hash22(i),f),dot(hash22(i+e.xy),f-e.xy),u.x),
             mix(dot(hash22(i+e.yx),f-e.yx),dot(hash22(i+e.xx),f-e.xx),u.x),u.y);
}
float noise3(vec3 p) {
  vec3 i=floor(p),f=fract(p);
  vec3 u=f*f*(3.0-2.0*f);
  vec3 e=vec3(1.0,0.0,0.0);
  return mix(mix(mix(dot(hash33(i),f),dot(hash33(i+e.xyy),f-e.xyy),u.x),
                 mix(dot(hash33(i+e.yxy),f-e.yxy),dot(hash33(i+e.xxy),f-e.xxy),u.x),u.y),
             mix(mix(dot(hash33(i+e.yyx),f-e.yyx),dot(hash33(i+e.xyx),f-e.xyx),u.x),
                 mix(dot(hash33(i+e.yxx),f-e.yxx),dot(hash33(i+e.xxx),f-e.xxx),u.x),u.y),u.z);
}
float fbmSoft(vec3 p) {
  float s=0.0,a=0.55;
  for(int i=0;i<4;i++) {
    s+=a*noise3(p);
    p=p*2.1+vec3(3.1,1.7,5.3);
    a*=0.42;
  }
  return s;
}
float gauss(float d,float s) { return exp(-d*d/(s*s)); }
float spot(vec2 p,vec2 c,vec2 s) { vec2 d=(p-c)/s; return exp(-dot(d,d)); }
mat2 rot2(float a) { float c=cos(a),s=sin(a); return mat2(c,s,-s,c); }
mat3 rotX(float a) { float c=cos(a),s=sin(a); return mat3(1.0,0.0,0.0,0.0,c,s,0.0,-s,c); }
mat3 rotY(float a) { float c=cos(a),s=sin(a); return mat3(c,0.0,-s,0.0,1.0,0.0,s,0.0,c); }

// Speech-like envelope: phrases and pauses, with a slow syllabic swell.
float voice(float s) {
  float phrase=smoothstep(-0.25,0.45,sin(s*0.57+0.6));
  float syllables=0.5+0.5*sin(s*2.9+1.7*sin(s*0.83));
  return 0.06+phrase*(0.30+0.56*syllables);
}

// Coverage and orb-space position of the orb drawn in this pixel, for the
// grain in main().
float cover;
vec2 orbP;

// Orb of radius R at the centre: p in orb units, r = |p|, z = sphere height.
// Returns the anti-aliased coverage of the disc.
float orb(vec2 q,float R,float px,out vec2 p,out float r,out float z) {
  p=q/R;
  r=length(p);
  z=sqrt(max(0.0,1.0-r*r));
  float e=px/R;
  cover=1.0-smoothstep(1.0-e,1.0+e,r);
  orbP=p;
  return cover;
}

// Soft grain fixed to the orb, not to the screen: value noise with cells of
// u_grain px on a 360 px frame, in orb units, so it breathes and wobbles with
// the orb. Fine grain with a trace of small clumps, about -0.5..0.5; the salt
// picks an independent grain.
float grainAt(vec2 g) {
  vec2 i=floor(g),f=fract(g);
  f=f*f*(3.0-2.0*f);
  return mix(mix(hash12(i),hash12(i+vec2(1.0,0.0)),f.x),
             mix(hash12(i+vec2(0.0,1.0)),hash12(i+vec2(1.0,1.0)),f.x),f.y)-0.5;
}
float grain(vec2 p,float salt) {
  vec2 g=p*(129.6/max(0.5,u_grain))+salt;
  return grainAt(g)+grainAt(g*0.45+11.0)*0.15;
}

// 11 Cel. A warm sky seen through a sphere; soft clouds drift across and bend
// at the rim. Voice: the orb breathes and the clouds swell.
vec3 cel(vec2 q,float px,float t,float m,vec3 bg) {
  vec2 p; float r,z;
  float a=orb(q,0.72*(1.0+0.045*m),px,p,r,z);
  if(a<=0.0) return bg;
  mat3 turn=rotY(t*0.05)*rotX(0.3);
  vec3 s=turn*vec3(p*0.82,sqrt(max(0.0,1.0-0.67*r*r)));
  vec3 sun=turn*normalize(vec3(-0.45,0.75,0.5));
  float h=0.5+0.5*p.y;
  vec3 sky=mix(ORANGE,APRICOT,smoothstep(0.0,0.8,h));
  sky=mix(sky,mix(AMBER,SHELL,0.4),smoothstep(0.55,1.1,h-0.2*p.x)*0.85);
  sky=mix(sky,DEEP,smoothstep(0.4,-0.05,h)*0.45);
  float drift=t*(0.03+0.05*m);
  vec3 c=s*1.15;
  vec3 w=vec3(noise3(c*0.8+vec3(0.0,0.0,drift)),noise3(c*0.8+vec3(5.2,1.3,2.8-drift)),0.0);
  vec3 cp=c+w*0.45+vec3(drift,0.0,0.0);
  float d=fbmSoft(cp);
  float d2=fbmSoft(cp+sun*0.16);
  float cover=-0.03-0.08*m;
  float cloud=smoothstep(cover,cover+0.16,d);
  float lit=clamp(0.55+(d-d2)*6.5,0.0,1.0);
  vec3 puff=mix(BLUSH,LIGHT,lit);
  puff=mix(puff,SAND,smoothstep(0.08,0.34,d)*(1.0-lit)*0.6);
  vec3 col=mix(sky,puff,cloud*0.96);
  float limb=1.0-z;
  col=mix(col,col*vec3(1.0,0.86,0.8),limb*limb*0.3);
  col=mix(col,SHELL,pow(limb,5.0)*smoothstep(-0.2,0.9,p.y)*0.3);
  return mix(bg,col,a);
}

// 12 Capvespre. The same sky at golden hour: a low sun behind a band of
// clouds that glow at their edges. Voice: the sun rises and the clouds hurry.
vec3 capvespre(vec2 q,float px,float t,float m,vec3 bg) {
  vec2 p; float r,z;
  float a=orb(q,0.72*(1.0+0.045*m),px,p,r,z);
  if(a<=0.0) return bg;
  vec3 s=vec3(p*0.8,sqrt(max(0.0,1.0-0.64*r*r)));
  vec2 sun=vec2(0.18,-0.34+0.1*m);
  float core=spot(p,sun,vec2(0.16,0.16));
  float halo=spot(p,sun,vec2(0.72,0.52));
  vec3 sky=mix(AMBER,ORANGE,smoothstep(-0.3,0.85,p.y));
  sky=mix(sky,DEEP,smoothstep(0.7,1.05,p.y)*0.3);
  sky=mix(sky,mix(ORANGE,AMBER,0.35),smoothstep(-0.55,-1.0,p.y)*0.7);
  sky=mix(sky,mix(AMBER,SHELL,0.55),halo*0.8);
  sky=mix(sky,LIGHT,core*(0.8+0.2*m));
  float drift=t*(0.035+0.05*m);
  vec3 cp=vec3(s.x*1.0+drift,s.y*2.3,s.z*1.0);
  cp.x+=noise3(cp*0.7+vec3(0.0,0.0,drift))*0.4;
  float d=fbmSoft(cp)+0.12*gauss(p.y-0.02,0.42)-0.06;
  float cover=-0.05*m;
  float cloud=smoothstep(cover,cover+0.12,d);
  float thin=1.0-smoothstep(cover+0.01,cover+0.2,d);
  vec3 body=mix(DEEP,ORANGE,0.25+0.25*halo);
  vec3 lining=mix(AMBER,LIGHT,0.55);
  vec3 cl=mix(body,lining,clamp(thin*(0.45+1.3*halo),0.0,1.0));
  vec3 col=mix(sky,cl,cloud*0.92);
  float limb=1.0-z;
  col=mix(col,col*vec3(1.0,0.86,0.8),limb*limb*0.3);
  return mix(bg,col,a);
}

// 13 Mel. Orange and amber folding into each other like honey, with one
// silky highlight riding the fold; the pattern crowds toward the rim as on a
// sphere. Voice: the flow quickens and folds deeper.
vec3 mel(vec2 q,float px,float t,float m,vec3 bg) {
  vec2 p; float r,z;
  float a=orb(q,0.72*(1.0+0.035*m),px,p,r,z);
  if(a<=0.0) return bg;
  vec2 uv=p/(0.72+0.28*z);
  float s=t*(0.05+0.08*m);
  vec2 w=vec2(noise2(uv*0.8+vec2(0.0,s)),noise2(uv*0.8+vec2(4.3,-s)));
  vec2 w2=vec2(noise2(uv*1.1+1.5*w+vec2(1.7,9.2)+s*0.7),noise2(uv*1.1+1.5*w+vec2(8.3,2.8)-s*0.6));
  float f=noise2(uv*0.8+(1.5+0.7*m)*w2+vec2(s*0.3,0.0))+0.18*noise2(uv*1.6+1.6*w2);
  vec3 col=mix(ORANGE,AMBER,smoothstep(-0.36,0.24,f));
  col=mix(col,DEEP,gauss(f+0.38,0.12)*0.35);
  col=mix(col,mix(AMBER,SHELL,0.4),gauss(f-0.2,0.12)*0.6);
  col=mix(col,LIGHT,gauss(f-0.25,0.07)*0.38);
  float limb=1.0-z;
  col=mix(col,col*vec3(1.0,0.82,0.72),pow(limb,1.5)*0.35);
  col=mix(col,mix(AMBER,LIGHT,0.6),spot(p,vec2(-0.34,0.44),vec2(0.42,0.3))*0.35);
  col=mix(col,SHELL,pow(limb,5.0)*smoothstep(0.0,1.0,p.y)*0.5);
  return mix(bg,col,a);
}

// 14 Ambre. A glass marble with light caught inside: a glowing nebula seen
// through the refraction, a softbox reflection and a caustic below. Voice:
// the core brightens and swells.
vec3 ambre(vec2 q,float px,float t,float m,vec3 bg) {
  vec2 p; float r,z;
  float a=orb(q,0.72*(1.0+0.03*m),px,p,r,z);
  if(a<=0.0) return bg;
  vec3 n=vec3(p,z);
  vec3 d=refract(vec3(0.0,0.0,-1.0),n,0.7);
  float len=-2.0*dot(n,d);
  vec3 X=n+d*len*0.5;
  float s=t*(0.06+0.1*m);
  vec3 cp=rotY(s)*X;
  float neb=fbmSoft(cp*1.15+vec3(0.0,s*0.6,0.0));
  float dist=length(X);
  float core=exp(-dist*dist*(4.2-1.4*m));
  float glow=core*(0.62+1.0*smoothstep(-0.25,0.3,neb));
  vec3 col=mix(DEEP,ORANGE,smoothstep(1.0,0.45,r));
  col=mix(col,mix(ORANGE,AMBER,0.6),smoothstep(0.08,0.55,glow));
  col=mix(col,mix(AMBER,SHELL,0.5),smoothstep(0.5,1.0,glow));
  col=mix(col,LIGHT,smoothstep(0.95,1.4,glow)*0.85);
  col=mix(col,mix(AMBER,SHELL,0.4),spot(p,vec2(0.26,-0.64),vec2(0.42,0.15))*(0.6+0.3*m));
  col=mix(col,mix(AMBER,LIGHT,0.5),exp(-dist*dist*14.0)*(0.25+0.45*m));
  vec3 R=reflect(vec3(0.0,0.0,-1.0),n);
  float box=smoothstep(1.0,0.45,length((R.xy-vec2(-0.34,0.8))/vec2(0.3,0.2)))*smoothstep(-0.2,0.2,R.z);
  col=mix(col,LIGHT,box*0.8);
  col=mix(col,LIGHT,spot(p,vec2(0.52,-0.22),vec2(0.04,0.04))*0.55);
  col=mix(col,mix(AMBER,PEACH,0.5),pow(1.0-z,3.0)*smoothstep(0.2,-0.9,p.y)*0.45);
  col=mix(col,LIGHT,gauss(r-0.985,0.014)*0.35);
  return mix(bg,col,a);
}

// 15 Nacre. A pearl: warm satin shading with overtones that drift from amber
// to tangerine across the surface. Voice: the overtones flow and the pearl
// warms from inside.
vec3 nacre(vec2 q,float px,float t,float m,vec3 bg) {
  vec2 p; float r,z;
  float a=orb(q,0.72*(1.0+0.03*m),px,p,r,z);
  if(a<=0.0) return bg;
  vec3 n=vec3(p,z);
  vec3 L=normalize(vec3(-0.55,0.6,0.58));
  vec3 H=normalize(L+vec3(0.0,0.0,1.0));
  float nl=dot(n,L);
  float diff=clamp((nl+0.45)/1.45,0.0,1.0);
  float nh=max(dot(n,H),0.0);
  vec3 s=rotY(t*0.06)*n;
  float flow=fbmSoft(s*0.9+vec3(0.0,t*0.05,0.0));
  float ph=dot(n,normalize(vec3(0.6,0.8,0.0)))*1.3+(1.0-z)*0.9+flow*0.9+t*0.05*(1.0+1.5*m);
  float band=0.5+0.5*cos(ph*TAU);
  vec3 body=mix(mix(PEACH,TANGERINE,0.25),SHELL,smoothstep(0.05,0.95,diff));
  vec3 tone=mix(mix(AMBER,CREAM,0.35),mix(TANGERINE,BLUSH,0.3),band);
  vec3 col=mix(body,tone,0.55*(0.35+0.65*smoothstep(0.15,0.85,diff)));
  col=mix(col,LIGHT,pow(nh,9.0)*0.6+pow(nh,110.0)*0.95);
  col=mix(col,mix(PEACH,TANGERINE,0.4),pow(1.0-z,3.5)*0.5*(1.0-diff));
  col=mix(col,CREAM,gauss(r-0.975,0.045)*0.35*smoothstep(0.1,-0.7,nl));
  col=mix(col,mix(AMBER,ORANGE,0.3),spot(p,vec2(0.05,-0.05),vec2(0.7,0.7))*0.32*m);
  return mix(bg,col,a);
}

// 16 Bombolla. A soap bubble, a speech bubble taken literally: a golden film
// swirls over a clear body and only the rim is dense. With u_noise the film
// itself is grainy: the grain dithers the film's density and colour, most in
// the half-tones where the film thins, and reaches the rim line and the
// silhouette, so it is made of the film's own colours and fades out in the
// clear centre. Voice: the film races and the bubble wobbles.
vec3 bombolla(vec2 q,float px,float t,float m,vec3 bg) {
  float th=atan(q.y,q.x);
  vec2 dir=vec2(cos(th),sin(th));
  float wob=noise3(vec3(dir*1.4,t*(0.35+0.4*m)))*(0.015+0.04*m);
  vec2 p; float r,z;
  float a=orb(q,0.72*(1.0+0.03*m+wob),px,p,r,z);
  if(a<=0.0) return bg;
  vec3 n=vec3(p,z);
  float fres=pow(1.0-z,1.4);
  float alpha=0.04+0.82*fres;
  float mid=clamp(alpha*(1.0-alpha)*4.0,0.0,1.0);
  vec3 s=rotY(t*0.05)*n;
  float film=fbmSoft(s*1.4+vec3(0.0,t*(0.06+0.08*m),0.0));
  float ph=fract(film*1.3-n.y*0.5+(1.0-z)*1.1+t*0.03+grain(p,53.0)*u_noise*0.4*(0.3+0.7*mid));
  vec3 tint=mix(AMBER,mix(AMBER,ORANGE,0.45),smoothstep(0.0,0.3,ph));
  tint=mix(tint,ORANGE,smoothstep(0.25,0.5,ph));
  tint=mix(tint,APRICOT,smoothstep(0.5,0.75,ph));
  tint=mix(tint,AMBER,smoothstep(0.75,1.0,ph));
  alpha=clamp(alpha+grain(p,17.0)*u_noise*(0.08+1.1*mid),0.0,1.0);
  float day=smoothstep(0.3,0.7,dot(bg,vec3(0.2126,0.7152,0.0722)));
  vec3 col=mix(bg+tint*alpha*0.9,mix(bg,tint,alpha),day);
  float rimA=clamp(gauss(r-0.99,0.014)*0.5*(1.0+grain(p,29.0)*u_noise*1.6),0.0,1.0);
  a=clamp(a+grain(p,41.0)*u_noise*1.4*gauss(r-1.0,0.02),0.0,1.0);
  col=mix(col,mix(ORANGE,APRICOT,0.5),rimA);
  return mix(bg,col,a);
}

void main() {
  vec2 q=(gl_FragCoord.xy-0.5*u_resolution)/(0.5*u_resolution.y);
  float px=2.0/u_resolution.y;
  float v=mix(u_level,voice(u_time),u_demo);
  float m=v*u_motion;
  float t=u_time*u_motion+u_phase*7.0;
  vec3 bg=u_background;
  vec3 col;
  cover=0.0;
  if(u_variant<0.5) col=cel(q,px,t,m,bg);
  else if(u_variant<1.5) col=capvespre(q,px,t,m,bg);
  else if(u_variant<2.5) col=mel(q,px,t,m,bg);
  else if(u_variant<3.5) col=ambre(q,px,t,m,bg);
  else if(u_variant<4.5) col=nacre(q,px,t,m,bg);
  else col=bombolla(q,px,t,m,bg);
  col=mix(bg,col,mix(0.8+0.2*v,1.0,u_motion));
  // Grain for the opaque orbs: it moves each pixel along the line between the
  // background and the orb's own colour, so it adds no new tone. The bubble
  // grains its own film.
  if(u_variant<4.5) col=mix(bg,col,1.0+grain(orbP,91.0)*u_noise*cover*0.6);
  col+=(hash12(gl_FragCoord.xy)-0.5)/255.0;
  gl_FragColor=vec4(clamp(col,0.0,1.0),1.0);
}
