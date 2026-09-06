# ===----------------------------------------------------------------------=== #
# Layer 0 -- the cosmos: a full-screen procedural background, behind everything.
#
# The layer stack a game composites, bottom to top, and the reason this file is
# numbered zero:
#
#   0  COSMOS    this: one triangle, one pixel shader, no geometry at all
#   1  CANVAS    the palette-indexed plane (bullets, beams, sparks)
#   2  SPRITES   the instanced pass
#   3  TEXT      the HUD
#
# It is opaque and it is drawn FIRST, so it is also the frame's clear: nothing
# needs ClearRenderTargetView when this runs, because a full-screen triangle
# that writes every pixel has already done it.
#
# THE SHADERS ARE THE REFERENCE'S, LIFTED VERBATIM. RASM's Galaxigans carries
# the same twelve backdrops in `projects/galaxigans/galaxigans_starfield.was`,
# already in HLSL and already on Direct3D 11 -- the same scene functions, the
# same scene numbering, and the same one-constant-buffer contract. The Mac
# tree's copy of these is Metal Shading Language and would have needed a
# translation pass; this one needs nothing at all. Extracted mechanically from
# the .ASCIISTRING block rather than retyped, because a shader transcribed by
# hand is a shader with a typo in it.
#
# Twelve scenes on one integer, and the numbering is the game's:
#
#   0  nebula (also the default)   6  wormhole
#   1  galaxy                      7  gas giant
#   2  black hole                  8  aurora
#   3  alien world                 9  pulsar
#   4  moon                       10  plasma
#   5  nova                       11  binary stars
#
# Two values reach the shader in one float4 at PS b0: `tparm.x` is time in
# seconds, `tparm.y` is the scene. Time advances on the WALL CLOCK rather than
# the game's fixed step, deliberately -- the sky should breathe at whatever
# rate the display runs while the simulation ticks at 30Hz underneath it, and
# it carries no state a game can collide with.
#
# The aspect ratio is baked at 1.7778 inside the scene functions, exactly as
# the reference has it. The canvas is 640x360 and nothing here is
# resolution-independent anyway.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer
from .canvas import _bytes
from .device import (
    compile_shader_blob,
    create_blend_state,
    create_buffer,
    create_pixel_shader,
    create_rasterizer_state,
    create_vertex_shader,
    draw,
    ia_set_topology,
    om_set_blend_state,
    om_set_render_targets,
    ps_set_constant_buffers,
    ps_set_shader,
    resolve_compiler,
    rs_set_state,
    set_viewport,
    update_subresource,
    vs_set_shader,
)

comptime SCENE_NEBULA = 0
comptime SCENE_GALAXY = 1
comptime SCENE_BLACK_HOLE = 2
comptime SCENE_ALIEN = 3
comptime SCENE_MOON = 4
comptime SCENE_NOVA = 5
comptime SCENE_WORMHOLE = 6
comptime SCENE_GAS_GIANT = 7
comptime SCENE_AURORA = 8
comptime SCENE_PULSAR = 9
comptime SCENE_PLASMA = 10
comptime SCENE_BINARY = 11
comptime SCENE_COUNT = 12

comptime _BIND_CONSTANT_BUFFER = 4
comptime _USAGE_DEFAULT = 0
comptime _TOPOLOGY_TRIANGLELIST = 4


comptime COSMOS_SHADER = String(
    """
cbuffer SCB:register(b0){float4 tparm;};
struct VO{float4 p:SV_Position;float2 uv:TEXCOORD0;};
VO SVS(uint i:SV_VertexID){VO o;float2 u=float2((i<<1)&2,i&2);o.p=float4(u.x*2-1,1-u.y*2,0,1);o.uv=u;return o;}
float h21(float2 p){return frac(sin(dot(p,float2(127.1,311.7)))*43758.5453);}
float3 scNebula(float2 uv,float t){
float px=uv.x*640.0,py=uv.y*360.0;
float n=sin(px*0.011+t*0.30)+sin(py*0.014-t*0.20)+sin((px+py)*0.007+t*0.15)+sin((px-py)*0.009-t*0.10);
float neb=(n+4.0)*0.125;
float3 col=float3(0.015+neb*0.05,0.010+neb*0.03,0.055+neb*0.20);
for(int L=0;L<3;L++){
float sp=16.0+L*30.0,cell=13.0+L*6.0;
float2 cp=float2(px,py-t*sp)/cell;float2 gi=floor(cp);float h=h21(gi);
if(h>0.90){float2 sub=frac(cp)-0.5;float d=dot(sub,sub);float tw=0.55+0.45*sin(t*3.0+h*50.0);col+=saturate(1.0-d*55.0)*tw*(0.45+0.5*float(L));}}
return col;}
float3 scGalaxy(float2 uv,float t){
float2 c=uv-0.5;c.x*=1.7778;
float r=length(c);float a=atan2(c.y,c.x);
float spiral=sin(2.0*(a+t*0.15)+6.5*log(r+0.06));
float arm=smoothstep(0.0,0.7,spiral)*exp(-r*2.6);
float core=exp(-r*r*38.0);
float3 col=float3(0.04,0.02,0.09);
col+=arm*float3(0.45,0.40,0.85)*0.7;
col+=core*float3(1.0,0.9,0.7);
col+=arm*0.35*float3(0.8,0.5,0.95)*(0.5+0.5*sin(r*60.0-t));
float2 sg=c*70.0;float2 sgi=floor(sg);float sh=h21(sgi);float2 ssb=frac(sg)-0.5;float sd=dot(ssb,ssb);
col+=(sh>0.93?1.0:0.0)*saturate(1.0-sd*55.0)*0.6*saturate(1.4-r*2.0);
return col;}
float3 scBlack(float2 uv,float t){
float2 c=uv-0.5;c.x*=1.7778;
float r=length(c);float a=atan2(c.y,c.x);
float horizon=smoothstep(0.12,0.105,r);
float rr=(r-0.19)*8.5;float ring=exp(-rr*rr);
float swirl=0.55+0.45*sin(a*3.0-t*2.2+22.0*r);
float3 disk=ring*swirl*float3(1.0,0.55,0.18);
float2 lp=c*(1.0+0.04/(r*r+0.02));
float2 sg=lp*72.0;float2 sgi=floor(sg);float sh=h21(sgi);float2 ssb=frac(sg)-0.5;float sd=dot(ssb,ssb);
float stars=(sh>0.95?1.0:0.0)*saturate(1.0-sd*45.0)*smoothstep(0.11,0.15,r);
float3 col=disk+stars*0.7+float3(0.02,0.01,0.03);
col*=(1.0-horizon);
return col;}
float3 scAlien(float2 uv,float t){
float3 sky=lerp(float3(0.02,0.05,0.08),float3(0.10,0.03,0.13),uv.y);
float2 pc=uv-float2(0.5,1.18);pc.x*=1.7778;
float pr=length(pc);float planet=smoothstep(0.63,0.62,pr);
float bands=0.5+0.5*sin(pc.y*34.0+sin(pc.x*7.0+t*0.2)*2.2);
float3 psurf=lerp(float3(0.20,0.45,0.18),float3(0.55,0.70,0.30),bands);
float z=sqrt(saturate(0.40-pr*pr));
float lit=saturate(dot(normalize(float3(pc.x,pc.y,z*1.5)),normalize(float3(-0.5,-0.6,0.6))));
psurf*=0.25+0.95*lit;
float3 col=lerp(sky,psurf,planet);
float st=h21(floor(uv*float2(220.0,130.0)));
col+=(st>0.985?1.0:0.0)*(1.0-planet)*0.8;
float2 mc=uv-float2(0.80,0.22);mc.x*=1.7778;float mr=length(mc);
float moon=smoothstep(0.05,0.045,mr);
float ml=saturate(dot(normalize(float3(mc.x,mc.y,0.05)),normalize(float3(-0.4,-0.5,0.7))));
col=lerp(col,float3(0.55,0.52,0.48)*(0.4+0.7*ml),moon);
return col;}
float craterH(float2 uv){
float h=0.0;
for(int k=0;k<3;k++){
float sc=5.0*pow(1.8,float(k));
float2 p=uv*sc;float2 gi=floor(p),gf=frac(p)-0.5;
float2 off=float2(h21(gi)-0.5,h21(gi+3.3)-0.5)*0.5;
float d=length(gf-off);float rad=0.16+0.16*h21(gi+7.7);
float rim=smoothstep(rad+0.05,rad,d)*smoothstep(rad-0.06,rad,d);
float bowl=smoothstep(rad,0.0,d);
h+=(rim*0.6-bowl*0.35)/(float(k)+1.0);}
return h;}
float3 scMoon(float2 uv,float t){
float2 uvp=uv+float2(t*0.008,0.0);uvp.x*=1.7778;
float cr=craterH(uvp);
float fine=h21(floor(uv*float2(320.0,180.0)))*0.05;
float3 col=float3(0.22,0.22,0.24)+cr*float3(0.55,0.54,0.58)+fine;
return saturate(col);}
float3 scNova(float2 uv,float t){
float2 c=uv-0.5;c.x*=1.7778;
float r=length(c);float a=atan2(c.y,c.x);
float ph=frac(t*0.12);
float er=(r-ph*0.75)*7.0;float ring=exp(-er*er);
float core=exp(-r*r*26.0)*(1.3-ph);
float rays=0.6+0.4*sin(a*20.0+t);
float3 col=float3(0.05,0.02,0.05);
col+=core*float3(1.0,0.92,0.7);
col+=ring*float3(1.0,0.55,0.25)*rays;
float st=h21(floor(c*55.0));
col+=(st>0.95?1.0:0.0)*0.35*saturate(1.3-r);
return col;}
float3 scWormhole(float2 uv,float t){
float2 c=uv-0.5;c.x*=1.7778;
float r=length(c)+0.05;float a=atan2(c.y,c.x);
float depth=0.32/r+t*0.6;
float ring=0.5+0.5*sin(depth*9.0);
float twist=0.5+0.5*sin(a*6.0+depth*2.5);
float3 col=lerp(float3(0.02,0.04,0.10),float3(0.20,0.55,0.95),ring*twist);
col*=saturate(r*2.6);
col+=exp(-r*r*55.0)*float3(0.7,0.85,1.0);
return col;}
float3 scGasGiant(float2 uv,float t){
float2 c=uv-float2(0.5,0.44);c.x*=1.7778;
float r=length(c);float planet=smoothstep(0.32,0.31,r);
float lat=c.y/0.33;
float bands=0.5+0.5*sin(lat*15.0+sin(lat*4.0+t*0.1)*1.4);
float3 surf=lerp(float3(0.55,0.42,0.24),float3(0.85,0.72,0.46),bands);
float2 sp=c-float2(0.11,-0.04);float spot=smoothstep(0.06,0.0,length(sp*float2(1.0,1.7)));
surf=lerp(surf,float3(0.82,0.32,0.20),spot*0.7);
float z=sqrt(saturate(0.105-r*r));
float lit=saturate(dot(normalize(float3(c.x,c.y,z*3.0)),normalize(float3(-0.5,-0.3,0.8))));
surf*=0.30+0.9*lit;
float2 rc=c*float2(1.0,3.4);float rr=length(rc);
float ring=smoothstep(0.40,0.43,rr)*smoothstep(0.60,0.57,rr)*(0.55+0.45*sin(rr*90.0));
float3 col=float3(0.02,0.02,0.05);
float st=h21(floor(uv*float2(220.0,130.0)));
col+=(st>0.985?1.0:0.0)*0.7;
col=lerp(col,float3(0.75,0.68,0.52),ring*(1.0-planet));
col=lerp(col,surf,planet);
return col;}
float3 scAurora(float2 uv,float t){
float3 col=float3(0.01,0.02,0.05);
float st=h21(floor(uv*float2(200.0,120.0)));
col+=(st>0.98?1.0:0.0)*0.6*smoothstep(0.55,0.0,uv.y);
float fil=0.62+0.38*sin(uv.x*140.0+sin(uv.y*8.0)*2.0+t*1.5);
for(int i=0;i<4;i++){
float fi=float(i);
float cx=0.18+fi*0.22+0.13*sin(uv.y*3.0+t*0.4+fi*1.7);
float fx=(uv.x-cx)*11.0;float band=exp(-fx*fx);
float hh=smoothstep(0.04,0.42,uv.y)*(1.0-smoothstep(0.50,0.96,uv.y));
float3 ac=lerp(float3(0.1,0.95,0.45),float3(0.45,0.2,0.9),frac(fi*0.37));
col+=band*hh*fil*ac*0.75;}
return col;}
float3 scPulsar(float2 uv,float t){
float2 c=uv-0.5;c.x*=1.7778;
float r=length(c);float a=atan2(c.y,c.x);
float core=exp(-r*r*70.0);
float beam=pow(abs(cos(a-t*1.5)),40.0)+pow(abs(cos(a-t*1.5+3.14159)),40.0);
beam*=exp(-r*1.6);
float3 col=float3(0.02,0.03,0.06);
col+=core*float3(0.85,0.92,1.0);
col+=beam*float3(0.45,0.65,1.0);
float st=h21(floor(c*60.0));
col+=(st>0.97?1.0:0.0)*0.45;
return col;}
float3 scPlasma(float2 uv,float t){
float px=uv.x*6.0,py=uv.y*4.0;
float v=sin(px+t)+sin(py*1.3-t*0.7)+sin((px+py)*0.8+t*0.5)+sin(length(float2(px,py)-3.0)*2.2-t);
float3 col=0.5+0.5*cos(float3(v,v+2.1,v+4.2));
col*=float3(0.42,0.30,0.52);
return col;}
float3 scBinary(float2 uv,float t){
float2 c=uv-0.5;c.x*=1.7778;
float2 s1=float2(cos(t*0.4),sin(t*0.4))*0.16;
float2 s2=-s1;
float d1=length(c-s1),d2=length(c-s2);
float3 col=float3(0.02,0.02,0.05);
col+=exp(-d1*d1*150.0)*float3(1.0,0.8,0.5)+exp(-d1*9.0)*float3(0.35,0.25,0.12);
col+=exp(-d2*d2*150.0)*float3(0.6,0.8,1.0)+exp(-d2*9.0)*float3(0.16,0.26,0.4);
float st=h21(floor(c*52.0));
col+=(st>0.97?1.0:0.0)*0.4;
return col;}
float4 SPS(VO v):SV_Target{
float t=tparm.x;int sc=(int)(tparm.y+0.5);float2 uv=v.uv;float3 col;
if(sc==1)col=scGalaxy(uv,t);
else if(sc==2)col=scBlack(uv,t);
else if(sc==3)col=scAlien(uv,t);
else if(sc==4)col=scMoon(uv,t);
else if(sc==5)col=scNova(uv,t);
else if(sc==6)col=scWormhole(uv,t);
else if(sc==7)col=scGasGiant(uv,t);
else if(sc==8)col=scAurora(uv,t);
else if(sc==9)col=scPulsar(uv,t);
else if(sc==10)col=scPlasma(uv,t);
else if(sc==11)col=scBinary(uv,t);
else col=scNebula(uv,t);
return float4(col,1.0);}
"""
)
"""RASM's galaxigans_starfield.was, verbatim between .ASCIISTRING and
.ENDASCIISTRING.

Read it and the whole trick of a procedural backdrop is visible: `h21` hashes
a grid cell, every star is that hash thresholded and shaped by a squared
distance, and the three parallax layers are one loop with a different speed
and cell size each time round. Nothing is uploaded and nothing is stored --
the entire sky costs one triangle."""


struct Cosmos(Movable):
    """The shader pane: layer 0, and the only layer that owns no data."""

    var device: Int
    var context: Int
    var vs: Int
    var ps: Int
    var cb: Int
    var rast: Int
    var blend_opaque: Int
    var parm: List[Float32]
    """{time, scene, 0, 0} -- the constant buffer, mirrored on the host."""

    def __init__(out self, device: Int, context: Int) raises:
        self.device = device
        self.context = context

        var compile = resolve_compiler()
        var empty = List[UInt8]()
        var src = _bytes(String(COSMOS_SHADER))
        var vs_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("SVS")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("SPS")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])

        self.cb = create_buffer(
            device, 16, _BIND_CONSTANT_BUFFER, _USAGE_DEFAULT
        )
        self.rast = create_rasterizer_state(device)
        self.blend_opaque = create_blend_state(device, False)
        self.parm = List[Float32](length=4, fill=0.0)

    def set_scene(mut self, scene: Int):
        """Which cosmos. Out of range falls back to the nebula, which is what
        the shader's own else-branch does anyway -- so a bad scene number is
        a backdrop rather than a black screen."""
        var s = scene
        if s < 0 or s >= SCENE_COUNT:
            s = SCENE_NEBULA
        self.parm[1] = Float32(s)

    def scene(self) -> Int:
        return Int(self.parm[1] + 0.5)

    def advance(mut self, dt: Float64):
        """Move the animation on by `dt` seconds."""
        self.parm[0] += Float32(dt)

    def set_time(mut self, seconds: Float64):
        """The animation clock, absolutely. A headless run sets this from a
        frame counter so two runs produce the same picture."""
        self.parm[0] = Float32(seconds)

    def render(mut self, rtv: Int, back_w: Int, back_h: Int) raises:
        """Draw the backdrop. First in the frame, opaque, no clear needed.

        The reference's StarRender leaves the viewport to its caller; this one
        sets it, because every caller in this tree wants the back buffer's and
        D3D11's default viewport is EMPTY -- a pass that forgets it rasterizes
        nothing at all, and reports nothing."""
        om_set_render_targets(self.context, rtv)
        set_viewport(self.context, back_w, back_h)
        update_subresource(
            self.context, self.cb,
            self.parm.unsafe_ptr().unsafe_bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin](),
            0,
        )
        ps_set_constant_buffers(self.context, self.cb)
        vs_set_shader(self.context, self.vs)
        ps_set_shader(self.context, self.ps)
        rs_set_state(self.context, self.rast)
        om_set_blend_state(self.context, self.blend_opaque)
        ia_set_topology(self.context, _TOPOLOGY_TRIANGLELIST)
        draw(self.context, 3)


def scene_name(scene: Int) -> String:
    """The backdrop's name, for a HUD line or a trace."""
    if scene == SCENE_GALAXY:
        return String("GALAXY")
    if scene == SCENE_BLACK_HOLE:
        return String("BLACK HOLE")
    if scene == SCENE_ALIEN:
        return String("ALIEN WORLD")
    if scene == SCENE_MOON:
        return String("MOON")
    if scene == SCENE_NOVA:
        return String("NOVA")
    if scene == SCENE_WORMHOLE:
        return String("WORMHOLE")
    if scene == SCENE_GAS_GIANT:
        return String("GAS GIANT")
    if scene == SCENE_AURORA:
        return String("AURORA")
    if scene == SCENE_PULSAR:
        return String("PULSAR")
    if scene == SCENE_PLASMA:
        return String("PLASMA")
    if scene == SCENE_BINARY:
        return String("BINARY STARS")
    return String("NEBULA")
