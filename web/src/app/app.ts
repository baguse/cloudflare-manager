import { Component, OnInit, signal, computed, NgZone } from '@angular/core';
import { CommonModule } from '@angular/common';
import { bootstrapApplication } from '@angular/platform-browser';
import { FormsModule } from '@angular/forms';
import * as QRCode from 'qrcode';

interface Tunnel { tunnelId: string; state: string; hostname: string; port: number; restartCount: number; notes?:string; tags?:string; serviceEnabled?:boolean; service?:string; }
interface DnsZone { id: string; name: string; }
interface DnsRecord { id: string; type: string; name: string; content: string; ttl: number; proxied: boolean; }
interface WebhookConfig { id: string; name: string; type: string; enabled: boolean; triggers: string[]; url?: string; }
interface RateAlert { id: string; name: string; domain: string; thresholdPerHour: number; enabled: boolean; }
interface Backup { timestamp: string; path: string; }

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, FormsModule],
  templateUrl: './app.html',
  styleUrls: ['./app.css']
})
export class AppComponent implements OnInit {
  apiUrl = signal(localStorage.getItem('cf_url')||''); apiKey = signal(localStorage.getItem('cf_key')||'');
  configured = computed(() => !!this.apiUrl() && !!this.apiKey());
  theme = signal(localStorage.getItem('cf_theme')||'dark');
  activeTab = signal('tunnels');
  tabs = [{id:'tunnels',icon:'dashboard',label:'Dashboard'},{id:'dns',icon:'dns',label:'DNS Editor'},{id:'webhooks',icon:'webhook',label:'Webhooks'},{id:'alerts',icon:'speed',label:'Rate Alerts'},{id:'backup',icon:'backup',label:'Backup & Restore'},{id:'settings',icon:'settings',label:'Settings'}];
  connected = signal(false);
  connDot = () => this.connected()?'dot-green':'dot-red';
  connLabel = () => this.connected()?'Connected':'Disconnected';
  tunnels = signal<Tunnel[]>([]);
  runningCount = computed(() => this.tunnels().filter(t=>t.state==='running').length);
  crashedCount = computed(() => this.tunnels().filter(t=>t.state==='crashed').length);
  stoppedCount = computed(() => this.tunnels().filter(t=>t.state==='stopped'||t.state==='inactive').length);
  zones: DnsZone[] = []; dnsZone = ''; dnsRecords: DnsRecord[] = []; showDnsForm = false; dnsForm: any = {type:'A',name:'',content:'',ttl:1,proxied:false}; editDnsId = '';
  webhooks: WebhookConfig[] = []; showWForm = false; wForm = {name:'',url:'',type:'http'};
  alerts: RateAlert[] = []; showAForm = false; aForm = {name:'',domain:'',thresholdPerHour:10000};
  backups: Backup[] = [];
  settings: any = {}; settingsKeys = () => Object.keys(this.settings);
  showBind = false; bind = {subdomain:'',zoneId:'',port:0};
  logsModal = signal(false); logLines = signal<string[]>([]);
  toastMsg = ''; toastError = false;
  editingNotes: string|null = null; notesText = ''; selectedTags: string[] = []; customTag = '';
  presetTags = ['prod','staging','dev','api','internal','testing','monitoring','backend','frontend','database','auth','webhook'];
  watcherEnabled = true;   daemonRunning = signal(false);
  refreshing = signal(false);

  ngOnInit() { document.documentElement.className = 'dark'; if (this.configured()) { this.connected.set(true); this.refreshAll(); } }

  constructor(private zone: NgZone) {}

  toggleTheme() { this.theme.set(this.theme()==='dark'?'light':'dark'); localStorage.setItem('cf_theme',this.theme()); document.documentElement.className=this.theme(); }

  connect() { localStorage.setItem('cf_url',this.apiUrl()); localStorage.setItem('cf_key',this.apiKey()); this.connected.set(true); this.refreshAll(); }

  async api(path:string, method='GET', data?:any): Promise<any> {
    const url = this.apiUrl().replace(/\/$/,'')+path;
    const headers: any = {Authorization:'Bearer '+this.apiKey()};
    if (data) headers['Content-Type']='application/json';
    const res = await fetch(url, {method, headers, body: data ? JSON.stringify(data) : undefined});
    if (!res.ok) throw await res.json().catch(()=>({error:res.statusText}));
    return res.json();
  }

  async refreshAll() { this.refreshing.set(true); await this.refreshTunnels(); await this.loadZones(); await this.loadWebhooks(); await this.loadAlerts(); await this.loadSettings(); this.refreshing.set(false); }

  async refreshTunnels() { this.refreshing.set(true); try { const r = await this.api('/api/tunnels/all','GET'); this.tunnels.set(r.tunnels||[]); this.connected.set(true); } catch { this.connected.set(false); this.tunnels.set([]); }
    try { const s = await this.api('/api/status','GET'); this.daemonRunning.set(s.running||s.ok||false); } catch {} this.refreshing.set(false); }
  async startDaemon() { try{await this.api('/api/daemon/start','POST');this.showToast('Daemon starting...');this.daemonRunning.set(true);}catch{this.showToast('Error',true);} }
  async stopDaemon() { if(!confirm('Stop daemon?'))return; try{await this.api('/api/daemon/stop','POST');this.showToast('Daemon stopped');this.daemonRunning.set(false);}catch{this.showToast('Error',true);} }
  stateClass(s:string) { return s==='running'?'badge-green':s==='crashed'?'badge-red':s==='starting'?'badge-yellow':s==='inactive'?'badge-gray':'badge-gray'; }

  async quickBind() {
    const z = this.zones.find(x=>x.id===this.bind.zoneId);
    if(!this.bind.subdomain||!this.bind.zoneId||!this.bind.port||!z) return this.showToast('All fields required',true);
    try{const r=await this.api('/api/bind','POST',{subdomain:this.bind.subdomain,zoneId:this.bind.zoneId,zoneName:z.name,port:+this.bind.port});this.showToast('Bound: '+r.url);this.showBind=false;this.refreshTunnels();}catch(e:any){this.showToast('Bind failed: '+(e.error||e.message),true);}
  }
  async quickBindExisting(tunnelId:string) {
    try{const r=await this.api('/api/tunnels/'+tunnelId+'/bind','POST');this.showToast('Tunnel bound');this.refreshTunnels();}catch(e:any){this.showToast('Bind failed: '+(e.error||e.message),true);}
  }
  async unbind(id:string) { if(!confirm('Unbind?'))return; try{await this.api('/api/tunnels/'+id,'DELETE');this.showToast('Unbound');this.refreshTunnels();}catch{this.showToast('Error',true);} }
  async deleteTunnel(id:string) { if(!confirm('Delete from Cloudflare?'))return; try{await this.api('/api/tunnels/'+id+'/delete','POST');this.showToast('Deleted');this.refreshTunnels();}catch{this.showToast('Error',true);} }
  async showLogs(id:string) { this.logsModal.set(true);this.logLines.set([]);try{const r=await this.api('/api/logs/'+id+'?limit=100','GET');this.logLines.set(r.logs||[]);}catch{this.logLines.set(['Error']);}}

  async loadZones() { try{const r=await this.api('/api/zones','GET');this.zones=r.zones||[];if(!this.dnsZone&&this.zones.length)this.dnsZone=this.zones[0].name;this.loadDns();}catch{} }
  async loadDns() { const z=this.zones.find(x=>x.name===this.dnsZone);if(!z)return;try{const r=await this.api('/api/dns?zoneId='+z.id,'GET');this.dnsRecords=r.records||[];}catch{} }
  async saveDns() { const z=this.zones.find(x=>x.name===this.dnsZone);if(!z)return; const data:any={zoneId:z.id,type:this.dnsForm.type,name:this.dnsForm.name,content:this.dnsForm.content,ttl:+this.dnsForm.ttl}; if(this.dnsForm.type==='MX') data.priority=+(this.dnsForm.priority||10); if(this.dnsForm.type==='A'||this.dnsForm.type==='AAAA'||this.dnsForm.type==='CNAME') data.proxied=!!this.dnsForm.proxied;
    if(this.editDnsId){ data.recordId=this.editDnsId; try{await this.api('/api/dns','PUT',data);this.showToast('Updated');this.showDnsForm=false;this.editDnsId='';this.loadDns();}catch{this.showToast('Error',true);} }
    else{ try{await this.api('/api/dns','POST',data);this.showToast('Created');this.showDnsForm=false;this.loadDns();}catch{this.showToast('Error',true);} }
  }
  editDns(r:any) { this.dnsForm={type:r.type,name:r.name,content:r.content,ttl:r.ttl,proxied:r.proxied||false,priority:r.priority||10}; this.editDnsId=r.id; this.showDnsForm=true; }
  dnsTypeBadge(t:string) { return t==='A'?'badge-green':t==='AAAA'?'badge-green':t==='CNAME'?'badge-yellow':t==='TXT'?'badge-gray':t==='MX'?'badge-red':t==='NS'?'badge-gray':'badge-gray'; }
  async deleteDns(r:DnsRecord) { if(!confirm('Delete?'))return;const z=this.zones.find(x=>x.name===this.dnsZone);if(!z)return;try{await this.api('/api/dns?zoneId='+z.id+'&recordId='+r.id,'DELETE');this.loadDns();}catch{this.showToast('Error',true);} }

  async loadWebhooks() { try{const r=await this.api('/api/webhooks','GET');this.webhooks=r.webhooks||[];}catch{} }
  async saveWebhook() { try{await this.api('/api/webhooks','POST',this.wForm);this.showWForm=false;this.loadWebhooks();this.showToast('Created');}catch{this.showToast('Error',true);} }
  async testWebhook(id:string) { try{await this.api('/api/webhooks/'+id+'/test','POST');this.showToast('Test passed');}catch{this.showToast('Test failed',true);} }
  async delWebhook(id:string) { if(!confirm('Delete?'))return;try{await this.api('/api/webhooks/'+id,'DELETE');this.loadWebhooks();this.showToast('Deleted');}catch{this.showToast('Error',true);} }

  async loadAlerts() { try{const r=await this.api('/api/rate-alerts','GET');this.alerts=r.alerts||[];}catch{} }
  async saveAlert() { try{await this.api('/api/rate-alerts','POST',this.aForm);this.showAForm=false;this.loadAlerts();this.showToast('Created');}catch{this.showToast('Error',true);} }
  async checkAlerts() { try{const r=await this.api('/api/rate-alerts/check','POST');this.showToast(JSON.stringify(r.results));}catch{this.showToast('Error',true);} }
  async delAlert(id:string) { if(!confirm('Delete?'))return;try{await this.api('/api/rate-alerts/'+id,'DELETE');this.loadAlerts();this.showToast('Deleted');}catch{this.showToast('Error',true);} }

  async loadBackups() { try{const r=await this.api('/api/backups','GET');this.backups=r.backups||[];}catch{} }
  async createBackup() { try{await this.api('/api/backup','POST');this.showToast('Created');this.loadBackups();}catch{this.showToast('Error',true);} }

  async loadSettings() { try{const r=await this.api('/api/settings','GET');this.settings=r.settings||{};}catch{} }
  async saveSettings() { try{await this.api('/api/settings','PATCH',this.settings);this.showToast('Saved');}catch{this.showToast('Error',true);} }

  async saveNotes() { if(!this.editingNotes)return;
    try{ await this.api('/api/tunnels/'+this.editingNotes+'/notes','PUT',{notes:this.notesText,tags:this.selectedTags.join(',')}); this.showToast('Saved'); this.editingNotes=null; this.refreshTunnels(); }catch{this.showToast('Error',true);}
  }
  togglePresetTag(tag:string) { const i=this.selectedTags.indexOf(tag); if(i>=0) this.selectedTags.splice(i,1); else { if(this.selectedTags.length>=5) return this.showToast('Max 5 tags',true); this.selectedTags.push(tag); } this.selectedTags=[...this.selectedTags]; }
  addCustomTag() { const t=this.customTag.trim(); if(!t) return; if(this.selectedTags.length>=5) return this.showToast('Max 5 tags',true); if(!this.selectedTags.includes(t)) this.selectedTags=[...this.selectedTags,t]; this.customTag=''; }
  removeTag(tag:string) { this.selectedTags=this.selectedTags.filter(t=>t!==tag); }
  async toggleService(tunnelId:string,hostname:string) {
    try{ const t = this.tunnels().find(x=>x.tunnelId===tunnelId); const v = !(t?.serviceEnabled); await this.api('/api/tunnels/'+tunnelId+'/service','PUT',{enabled:v}); this.showToast(v?'Auto-start enabled for '+hostname:'Auto-start disabled'); this.refreshTunnels(); }catch{this.showToast('Error',true);}
  }
  async copyUrl(url:string) { try{await navigator.clipboard.writeText(url);this.showToast('Copied!');}catch{this.showToast('Copy failed',true);} }
  qrData = signal(''); qrDataUrl = signal('');
  async showQr(url:string) {
    this.qrData.set(url);
    try { const dataUrl = await QRCode.toDataURL(url, {width:240,margin:2,color:{dark:'#0F172A',light:'#ffffff'}}); this.qrDataUrl.set(dataUrl); } catch { this.qrDataUrl.set(''); }
  }
  copyQrUrl() { navigator.clipboard.writeText(this.qrData()); this.showToast('URL copied!'); }
  openUrl(url:string) { window.open(url,'_blank'); }
  private _tagColors: Record<string,string> = {
    prod:'#E53935',production:'#E53935',staging:'#FF8F00',dev:'#42A5F5',development:'#42A5F5',
    api:'#7C4DFF',internal:'#00ACC1',testing:'#43A047',monitoring:'#FDD835',backend:'#1E88E5',
    frontend:'#43A047',database:'#8E24AA',auth:'#E53935',webhook:'#FF8F00',
  };
  tagColor(tag:string): string {
    const c = this._tagColors[tag.toLowerCase()] || '#6366F1';
    return 'tag-'+c.replace('#','');
  }
  getTagStyle(tag:string) {
    const c = this._tagColors[tag.toLowerCase()] || '#6366F1';
    return {'background': c+'26', 'color': c, 'border-color': c+'66'};
  }
  splitTags(tags?:string): string[] { return (tags||'').split(',').map(t=>t.trim()).filter(t=>t.length>0); }
  toggleWatcher() { this.watcherEnabled=!this.watcherEnabled; this.showToast('Watcher '+(this.watcherEnabled?'enabled':'disabled')); }
  async killDaemons() { if(!confirm('Kill all cloudflared processes?'))return; try{await this.api('/api/daemon/stop','POST');this.showToast('Daemon killed');}catch{this.showToast('Error',true);} }
  async getServiceState(tunnelId:string): Promise<boolean> {
    try{const r=await this.api('/api/settings','GET');return (r.settings||{})['service_'+tunnelId]==='true';}catch{return false;}
  }

  showToast(msg:string,err=false) { this.toastMsg=msg;this.toastError=err;setTimeout(()=>this.toastMsg='',3000); }
}

bootstrapApplication(AppComponent).catch(err=>console.error(err));
