precision highp float;

// Soft, rounded voice clouds. Pigment ramp from ProceduralNoise.metal.
// Broad overlapping volumes only: no domain noise, cutouts or narrow folds.
// Demo only. For audio, set u_demo=0 and supply a gated, smoothed u_level.
// u_motion=0 keeps geometry fixed and changes opacity only.
/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Núvol (0 Alè · 1 Brasa · 2 Plec · 3 Clariana · 4 Pols)
 * @default 0
 * @range 0, 4
 */
uniform float u_variant;
/**
 * @label Intensitat de la veu
 * @default 0.5
 * @range 0, 1
 */
uniform float u_level;
/**
 * @label Veu simulada (sense micròfon)
 * @default 1
 * @range 0, 1
 */
uniform float u_demo;
/**
 * @label Moviment (0 = només fosa)
 * @default 1
 * @range 0, 1
 */
uniform float u_motion;
/**
 * @label Fase
 * @default 0
 * @range 0, 10
 */
uniform float u_phase;
/**
 * @label Fons
 * @color
 * @default #FFFFFF
 */
uniform vec3 u_background;

float hash(vec2 p,float seed) {
  p+=seed*17.13;
  vec3 q=fract(vec3(p.xyx)*vec3(0.1031,0.1030,0.0973));
  q+=dot(q,q.yzx+33.33);
  return fract((q.x+q.y)*q.z);
}
mat2 turn(float a) { return mat2(cos(a),sin(a),-sin(a),cos(a)); }
float mist(vec2 p,vec2 center,vec2 size,float angle) {
  vec2 d=(turn(angle)*(p-center))/size;
  return exp(-dot(d,d));
}

void main() {
  vec2 q=(gl_FragCoord.xy-0.5*u_resolution)/(0.5*min(u_resolution.x,u_resolution.y));
  float demo=0.46+0.19*sin(u_time*0.76)+0.075*sin(u_time*1.39+1.2);
  float voice=mix(clamp(u_level,0.,1.),demo,clamp(u_demo,0.,1.));
  float motion=clamp(u_motion,0.,1.);
  float t=u_time*0.07*motion+u_phase;
  vec2 p=q/(0.99+0.018*voice*motion);
  vec2 drift=0.012*vec2(sin(t),cos(t*0.8))*motion;
  vec2 w=p+drift;
  float density=0.;
  float tone=0.5;

  if(u_variant<0.5) {
    density=0.90*mist(p,vec2(-0.06,0.04),vec2(0.49,0.52),-0.2)
           +0.40*mist(p,vec2(0.16,0.10),vec2(0.40,0.41),0.3)
           +0.24*mist(p,vec2(-0.10,-0.22),vec2(0.39,0.37),0.1);
    tone=0.51+0.35*mist(w,vec2(0.22,0.32),vec2(0.59,0.48),0.2)
             -0.30*mist(w,vec2(-0.15,-0.09),vec2(0.46,0.38),-0.3);
  } else if(u_variant<1.5) {
    density=0.92*mist(p,vec2(0.05,0.04),vec2(0.48,0.49),0.2)
           +0.40*mist(p,vec2(-0.20,0.13),vec2(0.37,0.36),-0.2)
           +0.36*mist(p,vec2(-0.10,-0.22),vec2(0.37,0.38),-0.3);
    tone=0.15+0.42*mist(w,vec2(0.17,0.43),vec2(0.60,0.42),0.2)
             +0.53*mist(w,vec2(0.34,-0.32),vec2(0.42,0.48),0.4)
             -0.16*mist(w,vec2(-0.17,-0.01),vec2(0.49,0.49),0.);
  } else if(u_variant<2.5) {
    density=0.94*mist(p,vec2(0.02,0.03),vec2(0.49,0.51),-0.35)
           +0.34*mist(p,vec2(-0.17,-0.13),vec2(0.38,0.40),-0.5)
           +0.32*mist(p,vec2(0.16,0.14),vec2(0.40,0.37),0.1);
    vec2 s=turn(-0.48)*w;
    tone=0.67-0.48*mist(s,vec2(-0.01,0.00),vec2(0.78,0.32),0.)
             +0.12*mist(s,vec2(0.04,0.39),vec2(0.65,0.45),0.);
  } else if(u_variant<3.5) {
    density=0.92*mist(p,vec2(-0.04,-0.02),vec2(0.49,0.49),0.1)
           +0.38*mist(p,vec2(0.13,0.17),vec2(0.38,0.40),0.2)
           +0.30*mist(p,vec2(-0.15,-0.17),vec2(0.40,0.36),-0.2);
    tone=0.43+0.48*mist(w,vec2(0.16,0.15),vec2(0.45,0.55),-0.35)
             -0.29*mist(w,vec2(-0.33,-0.07),vec2(0.37,0.52),0.2);
  } else {
    density=0.92*mist(p,vec2(-0.01,0.04),vec2(0.50,0.49),-0.2)
           +0.34*mist(p,vec2(0.17,0.12),vec2(0.39,0.38),0.2)
           +0.34*mist(p,vec2(-0.11,-0.21),vec2(0.38,0.41),-0.2);
    tone=0.46-0.41*mist(w,vec2(-0.17,0.20),vec2(0.48,0.44),-0.3)
             +0.41*mist(w,vec2(0.12,-0.29),vec2(0.51,0.45),0.2);
  }

  density=max(0.,density-0.015);
  float alpha=(1.-exp(-2.9*density*density))*(0.965+0.035*voice);
  // Original app gamut, unchanged: red=255, green=48...194, blue=0.
  float greenByte=clamp(128.655+(tone-0.5)*195.0,48.0,194.0);
  vec3 pigment=vec3(1.,greenByte/255.,0.);
  // Original grain, reduced to 18% so the broad gradient reads first.
  vec2 grain=mod(floor(gl_FragCoord.xy),64.);
  float redDark=hash(grain,3.)<0.5?hash(grain,4.)*10.:0.;
  float greenDark=hash(grain,5.)*27.;
  float greenLight=hash(grain,6.)*16.;
  float blueLight=hash(grain,7.)<0.5?hash(grain,8.)*10.:0.;
  pigment*=vec3(1.-redDark*0.18/255.,1.-greenDark*0.18/255.,1.);
  pigment+=vec3(0.,greenLight,blueLight)*0.18/255.;
  gl_FragColor=vec4(mix(u_background,clamp(pigment,0.,1.),alpha),1.);
}
