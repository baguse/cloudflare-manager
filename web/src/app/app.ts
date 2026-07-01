import { Component, OnInit, signal, computed, NgZone } from '@angular/core';
import { CommonModule } from '@angular/common';
import { bootstrapApplication } from '@angular/platform-browser';
import { FormsModule } from '@angular/forms';

interface Tunnel { tunnelId: string; state: string; hostname: string; port: number; restartCount: number; }
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
  stoppedCount = computed(() => this.tunnels().filter(t=>t.state==='stopped').length);
  zones: DnsZone[] = []; dnsZone = ''; dnsRecords: DnsRecord[] = []; showDnsForm = false; dnsForm = {type:'A',name:'',content:'',ttl:1};
  webhooks: WebhookConfig[] = []; showWForm = false; wForm = {name:'',url:'',type:'http'};
  alerts: RateAlert[] = []; showAForm = false; aForm = {name:'',domain:'',thresholdPerHour:10000};
  backups: Backup[] = [];
  settings: any = {}; settingsKeys = () => Object.keys(this.settings);
  showBind = false; bind = {subdomain:'',zoneId:'',port:0};
  logsModal = signal(false); logLines = signal<string[]>([]);
  toastMsg = ''; toastError = false;
  editingNotes: string|null = null; notesText = '';
  watcherEnabled = true; daemonRunning = false;

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

  async refreshAll() { this.refreshTunnels(); this.loadZones(); this.loadWebhooks(); this.loadAlerts(); this.loadSettings(); }

  async refreshTunnels() { try { const r = await this.api('/api/status','GET'); this.tunnels.set(r.tunnels||[]); this.connected.set(true); this.daemonRunning=r.daemonRunning||false; } catch { this.connected.set(false); } }
  stateClass(s:string) { return s==='running'?'badge-green':s==='crashed'?'badge-red':s==='starting'?'badge-yellow':'badge-gray'; }

  async quickBind() {
    const z = this.zones.find(x=>x.id===this.bind.zoneId);
    if(!this.bind.subdomain||!this.bind.zoneId||!this.bind.port||!z) return this.showToast('All fields required',true);
    try{const r=await this.api('/api/bind','POST',{subdomain:this.bind.subdomain,zoneId:this.bind.zoneId,zoneName:z.name,port:+this.bind.port});this.showToast('Bound: '+r.url);this.showBind=false;this.refreshTunnels();}catch(e:any){this.showToast('Bind failed: '+(e.error||e.message),true);}
  }
  async unbind(id:string) { if(!confirm('Unbind?'))return; try{await this.api('/api/tunnels/'+id,'DELETE');this.showToast('Unbound');this.refreshTunnels();}catch{this.showToast('Error',true);} }
  async deleteTunnel(id:string) { if(!confirm('Delete from Cloudflare?'))return; try{await this.api('/api/tunnels/'+id+'/delete','POST');this.showToast('Deleted');this.refreshTunnels();}catch{this.showToast('Error',true);} }
  async showLogs(id:string) { this.logsModal.set(true);this.logLines.set([]);try{const r=await this.api('/api/logs/'+id+'?limit=100','GET');this.logLines.set(r.logs||[]);}catch{this.logLines.set(['Error']);}}

  async loadZones() { try{const r=await this.api('/api/zones','GET');this.zones=r.zones||[];if(!this.dnsZone&&this.zones.length)this.dnsZone=this.zones[0].name;this.loadDns();}catch{} }
  async loadDns() { const z=this.zones.find(x=>x.name===this.dnsZone);if(!z)return;try{const r=await this.api('/api/dns?zoneId='+z.id,'GET');this.dnsRecords=r.records||[];}catch{} }
  async saveDns() { const z=this.zones.find(x=>x.name===this.dnsZone);if(!z)return;try{await this.api('/api/dns','POST',{zoneId:z.id,...this.dnsForm,ttl:+this.dnsForm.ttl});this.showDnsForm=false;this.loadDns();}catch{this.showToast('Error',true);} }
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

  async saveNotes() { if(!this.editingNotes)return; try{await this.api('/api/settings','PATCH',{[`tunnel_${this.editingNotes}_notes`]:this.notesText});this.showToast('Saved');this.editingNotes=null;}catch{this.showToast('Error',true);} }
  async toggleService(tunnelId:string,hostname:string) {
    try{
      const r=await this.api('/api/settings','GET');
      const s=r.settings||{};
      const k=`service_${tunnelId}`;
      const v=s[k]==='true'?'false':'true';
      await this.api('/api/settings','PATCH',{[k]:v});
      this.showToast(v==='true'?'Auto-start enabled for '+hostname:'Auto-start disabled');
      this.refreshTunnels();
    }catch{this.showToast('Error',true);}
  }
  async copyUrl(url:string) { try{await navigator.clipboard.writeText(url);this.showToast('Copied!');}catch{this.showToast('Copy failed',true);} }
  showQr(url:string) { const qrUrl='https://api.qrserver.com/v1/create-qr-code/?size=150x150&data='+encodeURIComponent(url); window.open(qrUrl,'_blank'); }
  toggleWatcher() { this.watcherEnabled=!this.watcherEnabled; this.showToast('Watcher '+(this.watcherEnabled?'enabled':'disabled')); }
  async killDaemons() { if(!confirm('Kill all cloudflared processes?'))return; try{await this.api('/api/daemon/stop','POST');this.showToast('Daemon killed');}catch{this.showToast('Error',true);} }
  async startDaemon() { try{await this.api('/api/daemon/start','POST');this.showToast('Daemon starting...');this.daemonRunning=true;}catch{this.showToast('Error',true);} }
  async stopDaemon() { if(!confirm('Stop daemon?'))return; try{await this.api('/api/daemon/stop','POST');this.showToast('Daemon stopped');this.daemonRunning=false;}catch{this.showToast('Error',true);} }
  async getServiceState(tunnelId:string): Promise<boolean> {
    try{const r=await this.api('/api/settings','GET');return (r.settings||{})['service_'+tunnelId]==='true';}catch{return false;}
  }

  showToast(msg:string,err=false) { this.toastMsg=msg;this.toastError=err;setTimeout(()=>this.toastMsg='',3000); }
}

bootstrapApplication(AppComponent).catch(err=>console.error(err));
