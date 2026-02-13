//// Dashboard HTML for the VIVINO real-time bioelectric monitor.
////
//// Contains the complete single-page dashboard with Chart.js graphs,
//// Three.js phase-space attractor, dual classifier bars (GPU + HDC),
//// label training buttons, organism selector, and stimulus controls.
//// All inline — no external files needed.

/// Returns the complete dashboard HTML page
pub fn html() -> String {
  styles() <> body() <> scripts()
}

fn styles() -> String {
  "<!DOCTYPE html>
<html lang='pt-BR'>
<head>
<meta charset='UTF-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>VIVINO</title>
<script src='https://cdn.jsdelivr.net/npm/chart.js@4.4.8/dist/chart.umd.min.js'></script>
<script src='https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js'></script>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;700&display=swap');
:root{
  --bg:#0a0a0f;--s1:#11131a;--s2:#1a1d28;
  --b1:#1e2130;--b2:#2a2d40;
  --t1:#e8eaf0;--t2:#8b90a0;--t3:#4a4e60;
  --red:#e53935;--grn:#43a047;--org:#fb8c00;--cyan:#00d4ff;--purple:#ab47bc;
  --dim:#1e2130;
  --mono:'JetBrains Mono',monospace;
  --card-border:1px solid rgba(30,33,48,.6);
  --card-shadow:0 2px 8px rgba(0,0,0,.3);
}
*{margin:0;padding:0;box-sizing:border-box}
html,body{height:100%;overflow:hidden}
body{background:var(--bg);color:var(--t1);font-family:var(--mono);font-size:14px}
.w{height:100vh;padding:10px 20px;display:flex;flex-direction:column;gap:8px}

/* Header */
.hdr{display:flex;align-items:baseline;gap:12px;flex-shrink:0}
.hdr h1{font-size:1.3em;font-weight:700;letter-spacing:2px;color:var(--cyan)}
.hdr .tag{font-size:.7em;color:var(--t3);font-weight:300}
.hdr .right{margin-left:auto;display:flex;align-items:center;gap:10px;font-size:.8em;color:var(--t3)}
.dot{width:8px;height:8px;border-radius:50%;background:var(--red);transition:all .3s ease}
.dot.on{background:var(--grn);box-shadow:0 0 10px var(--grn),0 0 20px rgba(67,160,71,.3)}

/* Metrics row */
.metrics{display:flex;gap:2px;flex-shrink:0}
.m{flex:1;background:var(--s1);padding:10px 16px;border-bottom:2px solid var(--dim);border:var(--card-border);border-bottom:2px solid var(--dim);transition:border-bottom-color .3s ease}
.m:first-child{border-radius:8px 0 0 8px}
.m:last-child{border-radius:0 8px 8px 0}
.m .k{font-size:.65em;text-transform:uppercase;letter-spacing:1.5px;color:var(--t3);margin-bottom:4px}
.m .v{font-size:2.2em;font-weight:700;line-height:1;transition:color .3s ease}
.m .v .u{font-size:.35em;color:var(--t3);font-weight:300;margin-left:2px}
.m.hi{border-bottom-color:var(--cyan)}

/* Pill */
.pill{display:inline-block;padding:4px 14px;border-radius:4px;font-size:.55em;font-weight:500;letter-spacing:1px;border:1px solid}

/* Main grid */
.grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;flex:1;min-height:0}
.chart-box{background:var(--s1);border-radius:8px;padding:10px 12px;overflow:hidden;display:flex;flex-direction:column;border:var(--card-border);box-shadow:var(--card-shadow)}
.chart-box .title{font-size:.6em;text-transform:uppercase;letter-spacing:1.5px;color:var(--t3);margin-bottom:4px;display:flex;align-items:center;gap:6px;flex-shrink:0}
.chart-box .title .live{width:6px;height:6px;border-radius:50%;background:var(--red);animation:bl .8s ease infinite}
@keyframes bl{0%,100%{opacity:1}50%{opacity:.15}}
.chart-wrap{flex:1;min-height:0;position:relative}
.chart-wrap canvas{position:absolute!important;inset:0;width:100%!important;height:100%!important}

/* Phase space */
.blob-box{background:var(--s1);border-radius:8px;position:relative;overflow:hidden;border:var(--card-border);box-shadow:var(--card-shadow)}
.blob-box canvas{display:block;width:100%;height:100%}
.blob-lbl{position:absolute;bottom:8px;left:0;right:0;text-align:center;font-size:.55em;color:var(--t3);letter-spacing:2px;text-transform:uppercase;opacity:.4}

/* Classifier horizontal bars */
.cls{background:var(--s1);border-radius:8px;padding:10px 14px;flex-shrink:0;border:var(--card-border);box-shadow:var(--card-shadow)}
.cls-row{display:grid;grid-template-columns:1fr 1fr;gap:0 24px}
.cls-half{display:flex;flex-direction:column;gap:2px}
.cls-title{font-size:.6em;text-transform:uppercase;letter-spacing:1.5px;color:var(--t3);margin-bottom:8px}
.cls-bars{display:grid;grid-template-columns:1fr 1fr;gap:3px 16px}
.cb{display:grid;grid-template-columns:80px 1fr 48px;align-items:center;gap:8px;height:20px;transition:opacity .2s}
.cb-name{font-size:.65em;color:var(--t3);letter-spacing:.5px;text-align:right;transition:color .3s}
.cb-track{height:12px;background:rgba(255,255,255,.03);border-radius:3px;overflow:hidden;position:relative}
.cb-fill{height:100%;border-radius:3px;transition:width .4s ease,background .4s ease;width:0%;min-width:1px}
.cb-pct{font-size:.65em;color:var(--t3);text-align:right;font-variant-numeric:tabular-nums;transition:color .3s}
.cb.on .cb-name{color:var(--t1);font-weight:500}
.cb.on .cb-pct{color:var(--t1);font-weight:700}
.cb-fill.s0{background:linear-gradient(90deg,#1b5e20,#43a047)}
.cb-fill.s1{background:linear-gradient(90deg,#2e7d32,#66bb6a)}
.cb-fill.s2{background:linear-gradient(90deg,#e65100,#fb8c00)}
.cb-fill.s3{background:linear-gradient(90deg,#6a1b9a,#ab47bc)}
.cb-fill.s4{background:linear-gradient(90deg,#b71c1c,#e53935)}
.cb-fill.s5{background:linear-gradient(90deg,#c62828,#ef5350)}

/* Bottom row */
.bottom{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;flex-shrink:0}
.card{background:var(--s1);border-radius:8px;padding:12px 14px;border:var(--card-border);box-shadow:var(--card-shadow)}
.card .title{font-size:.6em;text-transform:uppercase;letter-spacing:1.5px;color:var(--t3);margin-bottom:8px}
.stim-btns{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px;align-items:flex-end}
.btn-group{display:flex;flex-direction:column;gap:4px}
.btn-group-label{font-size:.55em;color:var(--t3);letter-spacing:1px;text-transform:uppercase;padding-left:2px}
.btn-group-row{display:flex;gap:6px;flex-wrap:wrap}
.stim-btn{background:rgba(255,255,255,.02);border:1px solid var(--b1);color:var(--t2);border-radius:6px;padding:8px 16px;font-family:var(--mono);font-size:.75em;cursor:pointer;transition:all .2s ease;position:relative;overflow:hidden}
.stim-btn:hover{border-color:var(--cyan);color:var(--cyan);background:rgba(0,212,255,.05)}
.stim-btn:active{transform:scale(.96)}
.stim-btn.sending{animation:btnPulse .3s ease}
@keyframes btnPulse{0%{box-shadow:0 0 0 0 rgba(0,212,255,.4)}100%{box-shadow:0 0 0 14px rgba(0,212,255,0)}}
.stim-btn.active{border-color:var(--cyan);color:var(--cyan);background:rgba(0,212,255,.08);box-shadow:0 0 12px rgba(0,212,255,.15)}
.stim-btn.active::after{content:'';position:absolute;bottom:0;left:0;right:0;height:2px;background:var(--cyan);animation:activeGlow 1.5s ease infinite}
@keyframes activeGlow{0%,100%{opacity:1}50%{opacity:.3}}
.stim-btn.single{color:var(--grn)}
.stim-btn.single:hover{border-color:var(--grn);color:var(--grn);background:rgba(67,160,71,.05)}
.stim-btn.single.sending{animation:btnPulseGrn .3s ease}
@keyframes btnPulseGrn{0%{box-shadow:0 0 0 0 rgba(67,160,71,.4)}100%{box-shadow:0 0 0 14px rgba(67,160,71,0)}}
.stim-btn.stop{color:var(--red)}
.stim-btn.stop:hover{border-color:var(--red);color:var(--red);background:rgba(229,57,53,.05)}
.stim-btn.stop.sending{animation:btnPulseRed .3s ease}
@keyframes btnPulseRed{0%{box-shadow:0 0 0 0 rgba(229,57,53,.4)}100%{box-shadow:0 0 0 14px rgba(229,57,53,0)}}
.stim-status{font-size:.75em;color:var(--t3);transition:color .3s}.stim-status.active{color:var(--cyan)}
.stim-log{max-height:50px;overflow-y:auto;font-size:.65em;color:var(--t3);line-height:1.8}

/* Label buttons */
.lbl-btn{background:rgba(255,255,255,.02);border:1px solid var(--b1);color:var(--t2);border-radius:6px;padding:6px 12px;font-family:var(--mono);font-size:.7em;cursor:pointer;transition:all .2s ease}
.lbl-btn:hover{border-color:var(--purple);color:var(--purple);background:rgba(171,71,188,.05)}
.lbl-btn:active{transform:scale(.96)}
.lbl-btn.sending{animation:btnPulsePurple .3s ease}
@keyframes btnPulsePurple{0%{box-shadow:0 0 0 0 rgba(171,71,188,.4)}100%{box-shadow:0 0 0 14px rgba(171,71,188,0)}}

/* Organism selector */
.org-btn{background:rgba(255,255,255,.02);border:1px solid var(--b1);color:var(--t2);border-radius:6px;padding:6px 12px;font-family:var(--mono);font-size:.7em;cursor:pointer;transition:all .2s ease}
.org-btn:hover{border-color:var(--cyan);color:var(--cyan);background:rgba(0,212,255,.05)}
.org-btn.active{border-color:var(--cyan);color:var(--cyan);background:rgba(0,212,255,.08)}

/* Learning stats */
.learn-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin-top:8px}
.learn-stat{text-align:center;padding:4px;background:rgba(255,255,255,.02);border-radius:4px}
.learn-stat .ls-name{font-size:.55em;color:var(--t3);letter-spacing:.5px;text-transform:uppercase}
.learn-stat .ls-val{font-size:.85em;font-weight:700;color:var(--t2)}
.cal-bar{height:4px;background:rgba(255,255,255,.03);border-radius:2px;margin-top:6px;overflow:hidden}
.cal-fill{height:100%;background:var(--cyan);border-radius:2px;transition:width .3s ease}

.tl{background:var(--s1);border-radius:8px;padding:12px 14px;border:var(--card-border);box-shadow:var(--card-shadow)}
.tl .title{font-size:.6em;text-transform:uppercase;letter-spacing:1.5px;color:var(--t3);margin-bottom:6px}
.tl canvas{width:100%;height:28px;display:block;border-radius:3px}

/* Toast notifications */
#toasts{position:fixed;top:16px;right:16px;z-index:999;display:flex;flex-direction:column;gap:6px;pointer-events:none}
.toast{padding:10px 16px;border-radius:6px;font-size:.75em;font-family:var(--mono);color:var(--t1);backdrop-filter:blur(8px);pointer-events:auto;animation:toastIn .25s ease,toastOut .3s ease 2.5s forwards;border-left:3px solid var(--cyan);background:rgba(17,19,26,.94);box-shadow:0 4px 20px rgba(0,0,0,.5);max-width:320px}
.toast.ok{border-left-color:var(--grn)}
.toast.warn{border-left-color:var(--org)}
.toast.err{border-left-color:var(--red)}
@keyframes toastIn{from{opacity:0;transform:translateX(40px)}to{opacity:1;transform:translateX(0)}}
@keyframes toastOut{from{opacity:1}to{opacity:0;transform:translateY(-10px)}}

/* Info */
.info{display:flex;gap:16px;font-size:.65em;color:var(--t3);padding:2px 0;justify-content:center;flex-shrink:0}

/* Responsive */
@media(max-width:900px){
  .w{height:auto;overflow-y:auto}
  .grid{grid-template-columns:1fr;flex:unset}
  .blob-box{min-height:300px;order:-1}
  .chart-wrap{min-height:200px}
  .chart-wrap canvas{position:relative!important;height:200px!important}
  .metrics{flex-wrap:wrap}.m{min-width:130px}
  .m .v{font-size:1.6em}
  .bottom{grid-template-columns:1fr}
  .cls-row{grid-template-columns:1fr}
  .cls-bars{grid-template-columns:1fr}
  .cb{grid-template-columns:70px 1fr 45px}
  .stim-btns{flex-direction:column;gap:8px}
  .learn-stats{grid-template-columns:repeat(2,1fr)}
}
@media(min-width:901px) and (max-width:1200px){
  .grid{grid-template-columns:1fr 1fr}
  .blob-box{grid-column:1/-1;min-height:300px;order:-1}
  .chart-wrap canvas{position:relative!important;height:240px!important}
  .chart-wrap{min-height:240px}
  .bottom{grid-template-columns:1fr 1fr}
}
@media(min-width:1800px){.m .v{font-size:2.6em}}
</style>
</head>"
}

fn body() -> String {
  "<body>
<div class='w'>
  <div id='toasts'></div>

  <div class='hdr'>
    <h1>VIVINO</h1>
    <span class='tag'>HIFA-01 &bull; <span id='organism'>H. tessellatus</span> &bull; 14-bit 67&micro;V/LSB</span>
    <div class='right'>
      <span class='dot' id='dot'></span>
      <span id='conn'>--</span>
      <span id='elapsed'>--:--</span>
      <span id='total'>0</span>
      <span><span id='rate'>--</span>Hz</span>
    </div>
  </div>

  <div class='metrics'>
    <div class='m hi'>
      <div class='k'>V<sub>m</sub></div>
      <div class='v' id='mv'>--<span class='u'>mV</span></div>
    </div>
    <div class='m'>
      <div class='k'>&Delta;V</div>
      <div class='v' id='dev'>--<span class='u'>mV</span></div>
    </div>
    <div class='m'>
      <div class='k'>&sigma;</div>
      <div class='v' id='std_card'>--<span class='u'>mV</span></div>
    </div>
    <div class='m'>
      <div class='k'>dV/dt</div>
      <div class='v' id='dvdt_card'>--<span class='u'>mV/s</span></div>
    </div>
    <div class='m'>
      <div class='k'>Estado</div>
      <div class='v' id='state'><span class='pill' style='color:var(--t3);border-color:var(--t3)'>--</span></div>
    </div>
  </div>

  <div class='grid'>
    <div class='chart-box'>
      <div class='title'><span class='live'></span>V<sub>m</sub> (mV)</div>
      <div class='chart-wrap'><canvas id='chartMv'></canvas></div>
    </div>
    <div class='blob-box' id='blobWrap'>
      <canvas id='blob3d'></canvas>
      <div class='blob-lbl'>ESPACO DE FASE &mdash; &tau;=250ms</div>
    </div>
    <div class='chart-box'>
      <div class='title'><span class='live'></span>&Delta;V (mV)</div>
      <div class='chart-wrap'><canvas id='chartDev'></canvas></div>
    </div>
  </div>

  <div class='cls'>
    <div class='cls-row'>
      <div class='cls-half'>
        <div class='cls-title'>GPU Classificador</div>
        <div class='cls-bars'>
          <div class='cb' id='gcb0'><span class='cb-name'>REPOUSO</span><div class='cb-track'><div class='cb-fill' id='gbf0'></div></div><span class='cb-pct' id='gp0'>--</span></div>
          <div class='cb' id='gcb1'><span class='cb-name'>CALMO</span><div class='cb-track'><div class='cb-fill' id='gbf1'></div></div><span class='cb-pct' id='gp1'>--</span></div>
          <div class='cb' id='gcb2'><span class='cb-name'>ATIVO</span><div class='cb-track'><div class='cb-fill' id='gbf2'></div></div><span class='cb-pct' id='gp2'>--</span></div>
          <div class='cb' id='gcb3'><span class='cb-name'>TRANSICAO</span><div class='cb-track'><div class='cb-fill' id='gbf3'></div></div><span class='cb-pct' id='gp3'>--</span></div>
          <div class='cb' id='gcb4'><span class='cb-name'>ESTIMULO</span><div class='cb-track'><div class='cb-fill' id='gbf4'></div></div><span class='cb-pct' id='gp4'>--</span></div>
          <div class='cb' id='gcb5'><span class='cb-name'>ESTRESSE</span><div class='cb-track'><div class='cb-fill' id='gbf5'></div></div><span class='cb-pct' id='gp5'>--</span></div>
        </div>
      </div>
      <div class='cls-half'>
        <div class='cls-title'>HDC k-NN Classificador</div>
        <div class='cls-bars'>
          <div class='cb' id='hcb0'><span class='cb-name'>REPOUSO</span><div class='cb-track'><div class='cb-fill' id='hbf0'></div></div><span class='cb-pct' id='hp0'>--</span></div>
          <div class='cb' id='hcb1'><span class='cb-name'>CALMO</span><div class='cb-track'><div class='cb-fill' id='hbf1'></div></div><span class='cb-pct' id='hp1'>--</span></div>
          <div class='cb' id='hcb2'><span class='cb-name'>ATIVO</span><div class='cb-track'><div class='cb-fill' id='hbf2'></div></div><span class='cb-pct' id='hp2'>--</span></div>
          <div class='cb' id='hcb3'><span class='cb-name'>TRANSICAO</span><div class='cb-track'><div class='cb-fill' id='hbf3'></div></div><span class='cb-pct' id='hp3'>--</span></div>
          <div class='cb' id='hcb4'><span class='cb-name'>ESTIMULO</span><div class='cb-track'><div class='cb-fill' id='hbf4'></div></div><span class='cb-pct' id='hp4'>--</span></div>
          <div class='cb' id='hcb5'><span class='cb-name'>ESTRESSE</span><div class='cb-track'><div class='cb-fill' id='hbf5'></div></div><span class='cb-pct' id='hp5'>--</span></div>
        </div>
      </div>
    </div>
  </div>

  <div class='bottom'>
    <div class='card'>
      <div class='title'>Estimulos</div>
      <div class='stim-btns'>
        <div class='btn-group'>
          <div class='btn-group-label'>Protocolos</div>
          <div class='btn-group-row'>
            <button class='stim-btn' data-cmd='H' onclick='sendCmd(\"H\")'>Habituacao</button>
            <button class='stim-btn' data-cmd='F' onclick='sendCmd(\"F\")'>Rapida</button>
            <button class='stim-btn' data-cmd='E' onclick='sendCmd(\"E\")'>Explorar</button>
          </div>
        </div>
        <div class='btn-group'>
          <div class='btn-group-label'>Acao</div>
          <div class='btn-group-row'>
            <button class='stim-btn single' data-cmd='S' onclick='sendCmd(\"S\")'>Pulso</button>
            <button class='stim-btn stop' data-cmd='X' onclick='sendCmd(\"X\")'>Parar</button>
          </div>
        </div>
      </div>
      <div class='stim-status' id='stimStatus'>Nenhum protocolo ativo</div>
      <div class='stim-log' id='stimLog'></div>
    </div>

    <div class='card'>
      <div class='title'>Rotular Estado (Online Learning)</div>
      <div class='btn-group-row' style='margin-bottom:8px'>
        <button class='lbl-btn' onclick='sendLabel(\"RESTING\")'>Repouso</button>
        <button class='lbl-btn' onclick='sendLabel(\"CALM\")'>Calmo</button>
        <button class='lbl-btn' onclick='sendLabel(\"ACTIVE\")'>Ativo</button>
        <button class='lbl-btn' onclick='sendLabel(\"TRANSITION\")'>Transicao</button>
        <button class='lbl-btn' onclick='sendLabel(\"STIMULUS\")'>Estimulo</button>
        <button class='lbl-btn' onclick='sendLabel(\"STRESS\")'>Estresse</button>
      </div>
      <div class='title'>Organismo</div>
      <div class='btn-group-row' style='margin-bottom:8px'>
        <button class='org-btn active' data-org='shimeji' onclick='sendOrg(\"shimeji\")'>Shimeji</button>
        <button class='org-btn' data-org='cannabis' onclick='sendOrg(\"cannabis\")'>Cannabis</button>
        <button class='org-btn' data-org='fungal_generic' onclick='sendOrg(\"fungal_generic\")'>Fungo Gen.</button>
      </div>
      <div class='title'>Aprendizado</div>
      <div class='cal-bar'><div class='cal-fill' id='calFill' style='width:0%'></div></div>
      <div style='font-size:.6em;color:var(--t3);margin-top:4px' id='calText'>Calibracao: 0/60</div>
      <div class='learn-stats' id='learnStats'>
        <div class='learn-stat'><div class='ls-name'>REP</div><div class='ls-val' id='lsR'>0</div></div>
        <div class='learn-stat'><div class='ls-name'>CAL</div><div class='ls-val' id='lsC'>0</div></div>
        <div class='learn-stat'><div class='ls-name'>ATV</div><div class='ls-val' id='lsA'>0</div></div>
        <div class='learn-stat'><div class='ls-name'>TRA</div><div class='ls-val' id='lsT'>0</div></div>
        <div class='learn-stat'><div class='ls-name'>EST</div><div class='ls-val' id='lsSt'>0</div></div>
        <div class='learn-stat'><div class='ls-name'>STR</div><div class='ls-val' id='lsSr'>0</div></div>
      </div>
    </div>

    <div class='tl'>
      <div class='title'>Linha do Tempo</div>
      <canvas id='timeline' height='24'></canvas>
    </div>
  </div>

  <div class='info'>
    <span>VIVINO v3.0</span>
    <span>Gleam/BEAM</span>
    <span>14-bit OS @ 20Hz</span>
    <span id='infoOrg'>H. tessellatus</span>
    <span id='fps'>0</span><span>q/s</span>
  </div>
</div>"
}

fn scripts() -> String {
  "
<script>
const MAX=400,$=id=>document.getElementById(id);
let sc=0,lr=Date.now(),total=0,frames=0,lastFps=Date.now();

const SN={RESTING:'REPOUSO',CALM:'CALMO',ACTIVE:'ATIVO',AGITATED:'AGITADO',TRANSITION:'TRANSICAO',STRONG_STIMULUS:'ESTIMULO',STIMULUS:'ESTIMULO',STRESS:'ESTRESSE'};
const SC={RESTING:'var(--grn)',CALM:'#66bb6a',ACTIVE:'var(--org)',AGITATED:'var(--red)',TRANSITION:'#ab47bc',STRONG_STIMULUS:'var(--red)',STIMULUS:'var(--org)',STRESS:'var(--red)'};
const ORG_DISPLAY={shimeji:'H. tessellatus (shimeji)',cannabis:'Cannabis sativa',fungal_generic:'Fungo generico'};

// Cached DOM refs
const _mv=$('mv'),_dev=$('dev'),_std=$('std_card'),_dvdt=$('dvdt_card'),_state=$('state'),
      _elapsed=$('elapsed'),_total=$('total'),_rate=$('rate'),_fps=$('fps'),
      _dot=$('dot'),_conn=$('conn'),_stimStatus=$('stimStatus'),_stimLog=$('stimLog'),
      _organism=$('organism'),_infoOrg=$('infoOrg'),
      _calFill=$('calFill'),_calText=$('calText');

// GPU classifier bars
const _gpuKeys=['RESTING','CALM','ACTIVE','TRANSITION','STIMULUS','STRESS'];
const _gcbEls=[0,1,2,3,4,5].map(i=>$('gcb'+i));
const _gbfEls=[0,1,2,3,4,5].map(i=>$('gbf'+i));
const _gpEls=[0,1,2,3,4,5].map(i=>$('gp'+i));
let _lastGpuBest=-1;

// HDC classifier bars
const _hcbEls=[0,1,2,3,4,5].map(i=>$('hcb'+i));
const _hbfEls=[0,1,2,3,4,5].map(i=>$('hbf'+i));
const _hpEls=[0,1,2,3,4,5].map(i=>$('hp'+i));
let _lastHdcBest=-1;

// Learning stat elements
const _lsEls={RESTING:$('lsR'),CALM:$('lsC'),ACTIVE:$('lsA'),TRANSITION:$('lsT'),STIMULUS:$('lsSt'),STRESS:$('lsSr')};

// Toast notifications
function showToast(msg,type){
  const t=document.createElement('div');
  t.className='toast '+(type||'ok');
  t.textContent=msg;
  $('toasts').appendChild(t);
  setTimeout(()=>t.remove(),3000);
}

// Command names
const CMD_NAMES={H:'Habituacao',F:'Rapida',E:'Explorar',S:'Pulso',X:'Parar'};

function mkChart(id,label,color,hasZero){
  const g=$(id).getContext('2d');
  const grad=g.createLinearGradient(0,0,0,200);
  grad.addColorStop(0,color+'15');grad.addColorStop(1,'transparent');
  return new Chart(g,{
    type:'line',
    data:{labels:[],datasets:[{label,data:[],borderColor:color,borderWidth:1.2,pointRadius:0,tension:.3,fill:true,backgroundColor:grad}]},
    options:{responsive:true,maintainAspectRatio:false,animation:false,
      interaction:{intersect:false,mode:'nearest',axis:'x'},
      scales:{x:{display:false},y:{
        grid:{color:ctx=>(hasZero&&ctx.tick.value===0)?'rgba(255,255,255,.1)':'rgba(255,255,255,.03)'},
        border:{display:false},
        ticks:{color:'#444',font:{family:\"'JetBrains Mono'\",size:9},maxTicksLimit:5,padding:8,
          callback:v=>Math.round(v)
        }
      }},
      plugins:{legend:{display:false},
        tooltip:{backgroundColor:'#11131a',titleFont:{family:\"'JetBrains Mono'\",size:10},
          titleColor:color,bodyColor:'#8b90a0',bodyFont:{family:\"'JetBrains Mono'\",size:10},
          cornerRadius:4,padding:{x:8,y:6},borderColor:'#1e2130',borderWidth:1,
          displayColors:false,callbacks:{label:c=>c.parsed.y.toFixed(1)+' mV'}
        }
      }
    }
  });
}
const cMv=mkChart('chartMv','Vm','#e53935',false);
const cDev=mkChart('chartDev','dV','#43a047',true);

let buf=[],rafId=0,lastSlow=0,stimEvents=[];

// Timeline
const TL_MAX=600,tlStates=[];
const tlColors={RESTING:'#1b5e20',CALM:'#43a047',ACTIVE:'#fb8c00',AGITATED:'#c62828',TRANSITION:'#7b1fa2',STRONG_STIMULUS:'#c62828',STIMULUS:'#e53935',STRESS:'#d32f2f'};
const tlCanvas=$('timeline'),tlCtx=tlCanvas.getContext('2d');
function drawTimeline(){
  const w=tlCanvas.width=tlCanvas.offsetWidth*2,h=tlCanvas.height=48;
  tlCtx.clearRect(0,0,w,h);if(!tlStates.length)return;
  const step=w/TL_MAX;
  for(let i=0;i<tlStates.length;i++){tlCtx.fillStyle=tlColors[tlStates[i]]||'#181818';tlCtx.fillRect(i*step,0,Math.ceil(step)+1,h);}
}

function fmtTime(s){const m=Math.floor(s/60),ss=Math.floor(s%60);return String(m).padStart(2,'0')+':'+String(ss).padStart(2,'0');}

// Update classifier bars (reusable for GPU and HDC)
function updateBars(data,keys,cbEls,bfEls,pEls,bestState,lastBestRef){
  const bIdx=keys.indexOf(bestState);
  for(let i=0;i<6;i++){
    const v=data[keys[i]];
    const pct=v?(v*100):0;
    pEls[i].textContent=v?pct.toFixed(1)+'%':'--';
    bfEls[i].style.width=pct.toFixed(1)+'%';
    bfEls[i].className='cb-fill s'+i;
    if(bIdx!==lastBestRef[0]){cbEls[i].className=i===bIdx?'cb on':'cb';}
  }
  lastBestRef[0]=bIdx;
}

let _gpuBestRef=[_lastGpuBest],_hdcBestRef=[_lastHdcBest];

function flush(){
  if(!buf.length){rafId=0;return;}
  const B=buf;buf=[];
  const md=cMv.data.datasets[0].data,ml=cMv.data.labels;
  const dd=cDev.data.datasets[0].data,dl=cDev.data.labels;
  for(const d of B){total++;sc++;const lbl=d.elapsed?d.elapsed.toFixed(2):'';md.push(d.mv);ml.push(lbl);dd.push(d.deviation);dl.push(lbl);if(typeof phaseUpdate==='function')phaseUpdate(d.deviation,d.gpu_state||d.state||'');if(md.length>MAX){md.shift();ml.shift();dd.shift();dl.shift();stimEvents=stimEvents.filter(s=>ml.includes(s.label));}}
  const d=B[B.length-1],now=Date.now();

  if(now-lr>=1000){_rate.textContent=sc;sc=0;lr=now;}
  _mv.innerHTML=d.mv.toFixed(1)+'<span class=u>mV</span>';
  const dv=d.deviation,adv=Math.abs(dv);
  _dev.innerHTML=(dv>=0?'+':'')+dv.toFixed(1)+'<span class=u>mV</span>';
  _dev.style.color=adv>30?'var(--red)':adv>15?'var(--org)':'var(--t1)';
  if(d.state){const nm=SN[d.state]||d.state,cl=SC[d.state]||'var(--t1)';
    _state.innerHTML='<span class=pill style=\"color:'+cl+';border-color:'+cl+'\">'+nm+'</span>';
    tlStates.push(d.state);if(tlStates.length>TL_MAX)tlStates.shift();drawTimeline();}
  _elapsed.textContent=fmtTime(d.elapsed);
  _total.textContent=total.toLocaleString('pt-BR');
  cMv.update('none');cDev.update('none');

  // Update organism display
  if(d.organism_display){
    _organism.textContent=d.organism_display;
    _infoOrg.textContent=d.organism_display;
  }

  if(now-lastSlow>=500){
    lastSlow=now;
    if(d.features){const f=d.features;
      _std.innerHTML=f.std.toFixed(1)+'<span class=u>mV</span>';
      _std.style.color=f.std>25?'var(--red)':f.std>8?'var(--org)':'var(--t1)';
      _dvdt.innerHTML=f.dvdt_max.toFixed(0)+'<span class=u>mV/s</span>';
      _dvdt.style.color=f.dvdt_max>500?'var(--red)':f.dvdt_max>200?'var(--org)':'var(--t1)';
    }
    // GPU bars
    if(d.gpu){updateBars(d.gpu,_gpuKeys,_gcbEls,_gbfEls,_gpEls,d.gpu_state,_gpuBestRef);}
    // HDC bars
    if(d.hdc){updateBars(d.hdc,_gpuKeys,_hcbEls,_hbfEls,_hpEls,d.hdc_state,_hdcBestRef);}
    // Learning stats
    if(d.learning){
      const L=d.learning;
      const pct=Math.min(100,L.calibration_progress/L.calibration_total*100);
      _calFill.style.width=pct+'%';
      _calText.textContent=L.calibration_complete?'Calibrado':'Calibracao: '+L.calibration_progress+'/'+L.calibration_total;
      if(L.exemplars){
        for(const k in _lsEls){if(L.exemplars[k]!==undefined)_lsEls[k].textContent=L.exemplars[k];}
      }
    }
  }
  frames++;
  if(now-lastFps>=2000){_fps.textContent=Math.round(frames*1e3/(now-lastFps));frames=0;lastFps=now;}
  rafId=0;
}

// Stimulus markers
const stimMarkerPlugin={id:'stimMarker',afterDraw(chart){
  if(!stimEvents.length)return;const xA=chart.scales.x,yA=chart.scales.y;if(!xA||!yA)return;
  const ctx=chart.ctx,labels=chart.data.labels;
  for(const se of stimEvents){
    const idx=labels.indexOf(se.label);if(idx<0)continue;
    const x=xA.getPixelForValue(idx);
    ctx.save();ctx.strokeStyle='rgba(251,140,0,0.6)';ctx.lineWidth=1;ctx.setLineDash([3,3]);
    ctx.beginPath();ctx.moveTo(x,yA.top);ctx.lineTo(x,yA.bottom);ctx.stroke();
    ctx.setLineDash([]);ctx.restore();
  }
}};
Chart.register(stimMarkerPlugin);

function onStim(d){
  stimEvents.push({label:d.elapsed.toFixed(2),stim_type:d.stim_type,protocol:d.protocol,count:d.count,duration:d.duration});
  if(stimEvents.length>50)stimEvents.shift();
  _stimStatus.textContent=d.protocol+' '+d.count+' — '+d.stim_type+' ('+d.duration+')';
  _stimStatus.className='stim-status active';
  const log=_stimLog,ev=document.createElement('div');
  ev.textContent=fmtTime(d.elapsed)+' '+d.protocol+' '+d.stim_type+' '+d.duration;
  log.prepend(ev);while(log.children.length>20)log.lastChild.remove();
  tlStates.push('STIMULUS');if(tlStates.length>TL_MAX)tlStates.shift();drawTimeline();
}

function onCmdAck(d){
  const isStop=d.cmd==='X';
  showToast(isStop?'Protocolo parado':'Enviado: '+CMD_NAMES[d.cmd],isStop?'warn':'ok');
  if(isStop){
    _stimStatus.textContent='Nenhum protocolo ativo';
    _stimStatus.className='stim-status';
    document.querySelectorAll('.stim-btn').forEach(b=>b.classList.remove('active'));
  }else{
    _stimStatus.textContent='Protocolo: '+CMD_NAMES[d.cmd];
    _stimStatus.className='stim-status active';
    document.querySelectorAll('.stim-btn').forEach(b=>{
      b.classList.toggle('active',b.dataset.cmd===d.cmd);
    });
  }
  const log=_stimLog,ev=document.createElement('div');
  ev.textContent=(_elapsed.textContent||'--:--')+' CMD '+CMD_NAMES[d.cmd];
  log.prepend(ev);while(log.children.length>20)log.lastChild.remove();
}

// === Label + Organism commands ===
var _ws=null;
function sendCmd(c){
  if(!_ws||_ws.readyState!==1){showToast('WebSocket desconectado','err');return;}
  _ws.send(c);
  const btn=document.querySelector('[data-cmd=\"'+c+'\"]');
  if(btn){btn.classList.add('sending');setTimeout(()=>btn.classList.remove('sending'),300);}
}

function sendLabel(state){
  if(!_ws||_ws.readyState!==1){showToast('WebSocket desconectado','err');return;}
  _ws.send('L:'+state);
  showToast('Rotulando: '+(SN[state]||state),'ok');
}

function sendOrg(org){
  if(!_ws||_ws.readyState!==1){showToast('WebSocket desconectado','err');return;}
  _ws.send('O:'+org);
}

function onLabelAck(d){
  showToast('Rotulado: '+(SN[d.label]||d.label),'ok');
}

function onOrganismAck(d){
  const name=ORG_DISPLAY[d.organism]||d.organism;
  showToast('Organismo: '+name,'ok');
  _organism.textContent=name;
  _infoOrg.textContent=name;
  document.querySelectorAll('.org-btn').forEach(b=>{
    b.classList.toggle('active',b.dataset.org===d.organism);
  });
}

function connect(){
  const ws=new WebSocket('ws://'+location.host+'/ws');_ws=ws;
  ws.onopen=()=>{_dot.className='dot on';_conn.textContent='ON';showToast('Conectado','ok');};
  ws.onclose=()=>{_ws=null;_dot.className='dot';_conn.textContent='OFF';document.querySelectorAll('.stim-btn').forEach(b=>b.classList.remove('active'));setTimeout(connect,2000);};
  ws.onerror=()=>ws.close();
  ws.onmessage=e=>{const d=JSON.parse(e.data);
    if(d.type==='stim'){onStim(d);}
    else if(d.type==='cmd_ack'){onCmdAck(d);}
    else if(d.type==='label_ack'){onLabelAck(d);}
    else if(d.type==='organism_ack'){onOrganismAck(d);}
    else{buf.push(d);if(!rafId)rafId=requestAnimationFrame(flush);}
  };
}
connect();

// === PHASE SPACE ATTRACTOR (Takens' delay embedding) ===
(function(){
if(typeof THREE==='undefined')return;
var bw=$('blobWrap'),bc=$('blob3d');if(!bw||!bc)return;
var scene=new THREE.Scene(),cam=new THREE.PerspectiveCamera(50,1,.1,100);
cam.position.set(3,2,3);cam.lookAt(0,0,0);
var ren=new THREE.WebGLRenderer({canvas:bc,alpha:true,antialias:true});
ren.setPixelRatio(Math.min(devicePixelRatio,1.5));ren.setClearColor(0,0);
var TAU=5,BUF=400,TRAIL=200;
var ring=new Float32Array(BUF),ri=0,rc=0;
var tP=new Float32Array(TRAIL*3),tC=new Float32Array(TRAIL*3);
var tG=new THREE.BufferGeometry();
tG.setAttribute('position',new THREE.BufferAttribute(tP,3));
tG.setAttribute('color',new THREE.BufferAttribute(tC,3));
var trail=new THREE.Line(tG,new THREE.LineBasicMaterial({vertexColors:true,transparent:true,opacity:.85}));
scene.add(trail);
var dM=new THREE.MeshBasicMaterial({color:0x43a047,transparent:true,opacity:.9});
var dot=new THREE.Mesh(new THREE.SphereGeometry(.06,10,10),dM);dot.visible=false;scene.add(dot);
var gM=new THREE.MeshBasicMaterial({color:0x43a047,transparent:true,opacity:.2});
var glow=new THREE.Mesh(new THREE.SphereGeometry(.15,10,10),gM);glow.visible=false;scene.add(glow);
var aM=new THREE.LineBasicMaterial({color:0x1a1a1a,transparent:true,opacity:.5});
[[2,0,0],[0,2,0],[0,0,2]].forEach(function(p){
  var g=new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(-p[0],-p[1],-p[2]),new THREE.Vector3(p[0],p[1],p[2])]);
  scene.add(new THREE.Line(g,aM));
});
var mxA=10;
var SC={RESTING:[.26,.63,.28],CALM:[.4,.73,.42],ACTIVE:[.98,.55,0],AGITATED:[.9,.16,.16],TRANSITION:[.67,.28,.74],STIMULUS:[.9,.22,.21],STRONG_STIMULUS:[.9,.22,.21],STRESS:[.83,.18,.18]};
var cR=[.26,.63,.28],tR=[.26,.63,.28];
function onR(){var w=bw.clientWidth,h=bw.clientHeight;if(w>0&&h>0){ren.setSize(w,h);cam.aspect=w/h;cam.updateProjectionMatrix();}}
addEventListener('resize',onR);setTimeout(onR,80);
var rot=0,lf=0;
function anim(ts){requestAnimationFrame(anim);if(ts-lf<33)return;lf=ts;
  cR[0]+=(tR[0]-cR[0])*.08;cR[1]+=(tR[1]-cR[1])*.08;cR[2]+=(tR[2]-cR[2])*.08;
  rot+=.004;var r=4.5;
  cam.position.x=Math.sin(rot)*r;cam.position.z=Math.cos(rot)*r;cam.position.y=1.5+Math.sin(rot*.3)*.8;
  cam.lookAt(0,0,0);
  if(rc>=TAU*2+1){
    var cnt=Math.min(TRAIL,rc-TAU*2),sc=2/Math.max(mxA,1);
    for(var i=0;i<cnt;i++){
      var idx=(ri-cnt+i+BUF)%BUF;
      tP[i*3]=ring[idx]*sc;tP[i*3+1]=ring[(idx-TAU+BUF)%BUF]*sc;tP[i*3+2]=ring[(idx-TAU*2+BUF)%BUF]*sc;
      var a=i/cnt;a*=a;
      tC[i*3]=cR[0]*(.05+a*.95);tC[i*3+1]=cR[1]*(.05+a*.95);tC[i*3+2]=cR[2]*(.05+a*.95);
    }
    tG.setDrawRange(0,cnt);tG.attributes.position.needsUpdate=true;tG.attributes.color.needsUpdate=true;
    if(cnt>0){var li=(cnt-1)*3;dot.position.set(tP[li],tP[li+1],tP[li+2]);dot.visible=true;
      dM.color.setRGB(cR[0],cR[1],cR[2]);glow.position.copy(dot.position);glow.visible=true;gM.color.setRGB(cR[0],cR[1],cR[2]);}
  }else{dot.visible=false;glow.visible=false;tG.setDrawRange(0,0);}
  ren.render(scene,cam);
}
requestAnimationFrame(anim);
window.phaseUpdate=function(dev,state){
  ring[ri]=dev;ri=(ri+1)%BUF;rc++;
  var a=Math.abs(dev);if(a>mxA)mxA=a;else mxA+=(Math.max(a,5)-mxA)*.001;
  var s=SC[state];if(s){tR[0]=s[0];tR[1]=s[1];tR[2]=s[2];}
};
})();
</script>
</body>
</html>"
}
