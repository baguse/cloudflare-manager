import { Component, OnInit, OnDestroy, signal, computed, inject, effect, DestroyRef } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ModalService } from '../modal.service';
import { ToastService } from '../toast.service';
import { ConfirmService } from '../confirm.service';
import * as QRCode from 'qrcode';

interface Tunnel { tunnelId: string; name?: string; state: string; hostname: string; port: number; protocol?: string; restartCount: number; notes?:string; tags?:string; serviceEnabled?:boolean; service?:string; status?: string; }
interface DnsZone { id: string; name: string; }

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    @if (error()) { <div class="card" style="color:var(--red);text-align:center"><span class="material-icons" style="font-size:20px;vertical-align:middle">error_outline</span> {{error()}} <button class="btn btn-ghost btn-xs" (click)="refreshAll()">Retry</button></div> }
    @if (api.cloudflared() && !api.cloudflared()?.installed) {
      <div class="card" style="border-left:4px solid var(--red);background:rgba(248,113,113,0.08);display:flex;align-items:center;gap:12px;margin-bottom:16px">
        <span class="material-icons" style="color:var(--red);font-size:24px">error</span>
        <div style="flex:1">
          <b style="color:var(--red);font-size:14px">cloudflared is not installed</b>
          <div style="font-size:12px;color:var(--muted);margin-top:2px">
            The <code>cloudflared</code> binary was not found on the host system. Tunnels cannot be bound or started until cloudflared is installed.
          </div>
        </div>
        <button class="btn btn-ghost btn-xs" (click)="recheckCloudflared()"><span class="material-icons" style="font-size:14px">refresh</span> Re-check</button>
      </div>
    }
    <div class="page-header"><h1>Dashboard</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="refreshAll()"><span class="material-icons" style="font-size:16px">refresh</span></button><button class="btn btn-primary btn-sm" (click)="showBind=true">+ Quick Bind</button></div></div>
    @if (showBind) {
      <div class="card bind-row">
        <select class="input" [(ngModel)]="bind.protocol" style="width:105px;font-weight:600">
          <option value="http">http://</option>
          <option value="https">https://</option>
          <option value="ssh">ssh://</option>
          <option value="tcp">tcp://</option>
          <option value="rdp">rdp://</option>
        </select>
        <input class="input" [(ngModel)]="bind.subdomain" placeholder="Subdomain" style="flex:1;min-width:140px">
        <select class="input" [(ngModel)]="bind.zoneId" style="flex:1;min-width:160px">
          <option value="">Select domain...</option>
          @for (z of zones(); track z.id) { <option [value]="z.id">{{z.name}}</option> }
        </select>
        <input class="input" [(ngModel)]="bind.port" (ngModelChange)="onPortChange($event)" placeholder="Port" type="number" style="width:90px">
        <label style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--muted);cursor:pointer;white-space:nowrap;user-select:none" title="Automatically start this tunnel on boot with background daemon">
          <input type="checkbox" [(ngModel)]="bind.serviceEnabled" style="accent-color:var(--accent)">
          <span>Auto-start</span>
        </label>
        <button class="btn btn-primary btn-sm" (click)="quickBind()">Bind</button>
      </div>
      @if (bind.protocol === 'ssh') {
        <div style="font-size:11px;color:var(--accent);margin:-4px 0 12px 6px;display:flex;align-items:center;gap:4px">
          <span class="material-icons" style="font-size:14px">info</span>
          SSH tunnel will route traffic to <code>ssh://localhost:{{bind.port||22}}</code>. Connect using <code>cloudflared access ssh</code> or Cloudflare Access browser terminal.
        </div>
      }
    }
    <div class="stats-row"><div class="stat"><span class="stat-num">{{tunnels().length}}</span><span class="stat-label">Tunnels</span></div><div class="stat"><span class="stat-num green">{{runningCount()}}</span><span class="stat-label">Running</span></div><div class="stat"><span class="stat-num red">{{crashedCount()}}</span><span class="stat-label">Crashed</span></div><div class="stat"><span class="stat-num muted">{{stoppedCount()}}</span><span class="stat-label">Inactive</span></div></div>
    <div class="card">
      @if (tunnels().length > 0) {
        <table><thead><tr><th>Status</th><th>Hostname</th><th>Protocol / Port</th><th>Actions</th></tr></thead><tbody>
          @for (t of tunnels(); track t.tunnelId) {
            <tr><td><span class="badge" [ngClass]="stateClass(t.state)">{{t.state}}</span></td>
              <td>{{t.hostname||'-'}}
                @if (t.serviceEnabled) {
                  <span class="service-chip" title="Auto-start on boot is enabled (click to configure)" (click)="openServiceModal(t)">
                    <span class="material-icons" style="font-size:12px;vertical-align:middle">shield</span>Auto-start
                  </span>
                }
                @for (tag of splitTags(t.tags); track tag) { <span class="tag-chip" [ngStyle]="getTagStyle(tag)">{{tag}}</span> }
                @if (t.notes) { <span class="note-text" title="{{t.notes}}"><span class="material-icons" style="font-size:12px;color:var(--accent);vertical-align:middle">sticky_note_2</span>{{t.notes}}</span> }
              </td><td class="muted">
                <span class="proto-badge" [ngClass]="'proto-' + getProto(t)">{{getProto(t).toUpperCase()}}</span>
                <span style="margin-left:6px">{{t.port||extractPort(t.service)||'-'}}</span>
              </td><td><div class="action-cell">
                <button class="btn btn-ghost btn-xs" title="Notes" (click)="editingNotes=t.tunnelId;notesText=t.notes||'';selectedTags=splitTags(t.tags)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">edit_note</span></button>
                <button class="btn btn-ghost btn-xs" [title]="t.serviceEnabled?'Auto-start enabled (click to configure)':'Auto-start disabled (click to configure)'" (click)="openServiceModal(t)" [style.color]="t.serviceEnabled?'var(--green)':''" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">shield</span></button>
                @if (t.state!=='inactive') {
                  @if (getProto(t) === 'ssh') {
                    <button class="btn btn-ghost btn-xs" title="Copy SSH command" (click)="copySsh(t.hostname)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">terminal</span></button>
                  }
                  <button class="btn btn-ghost btn-xs" title="Copy URL" (click)="copyUrl(tunnelUrl(t))" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">content_copy</span></button>
                  <button class="btn btn-ghost btn-xs" title="QR Code" (click)="showQr(tunnelUrl(t))" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">qr_code</span></button>
                  <button class="btn btn-ghost btn-xs" title="Logs" (click)="showLogs(t.tunnelId)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">article</span></button>
                  <button class="btn btn-ghost btn-xs" title="Stop" (click)="unbind(t.tunnelId)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">stop_circle</span></button>
                } @else {
                  <button class="btn btn-ghost btn-xs" title="QR Code" (click)="showQr(tunnelUrl(t))" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">qr_code</span></button>
                  @if (bindTunnelId===t.tunnelId) {
                    <select class="input" [(ngModel)]="bindProtocol" style="width:75px;padding:2px 4px;font-size:11px">
                      <option value="http">http</option>
                      <option value="https">https</option>
                      <option value="ssh">ssh</option>
                      <option value="tcp">tcp</option>
                      <option value="rdp">rdp</option>
                    </select>
                    <input class="input" type="number" [(ngModel)]="bindPort" placeholder="Port" style="width:60px;padding:2px 6px;font-size:11px" (keyup.enter)="quickBindExisting(t.tunnelId)">
                    <button class="btn btn-primary btn-xs" (click)="quickBindExisting(t.tunnelId)">Go</button>
                  } @else {
                    <button class="btn btn-primary btn-xs" (click)="startBindExisting(t)" [disabled]="actingTunnelId()==t.tunnelId">Bind</button>
                  }
                }
                <button class="btn btn-ghost btn-xs danger" title="Delete" (click)="deleteTunnel(t.tunnelId)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">delete_outline</span></button>
              </div></td></tr>
          }
        </tbody></table>
      } @else {
        <div class="empty">No tunnels yet.</div>
      }
    </div>

    @if (editingNotes) {
      <div class="modal-overlay" (click)="editingNotes=null"><div class="modal" (click)="$event.stopPropagation()" style="width:480px">
        <div class="modal-head"><span class="material-icons" style="font-size:20px;color:var(--accent)">edit_note</span><b>Tunnel Notes &amp; Tags</b><button class="btn btn-ghost btn-sm" (click)="editingNotes=null"><span class="material-icons" style="font-size:18px">close</span></button></div>
        <label class="field-label">Notes</label>
        <textarea class="input" [(ngModel)]="notesText" placeholder="e.g. staging env, behind SSO, owned by &#64;alice" rows="3" style="resize:vertical;width:100%;box-sizing:border-box"></textarea>
        <label class="field-label">Tags <span style="font-size:10px;font-weight:400;color:var(--muted)">Max 5 tags</span></label>
        <div class="tag-row">
          @for (tag of selectedTags; track tag) { <span class="tag-chip" [ngStyle]="getTagStyle(tag)" style="cursor:default">{{tag}}<span class="tag-close" (click)="removeTag(tag)">&times;</span></span> }
        </div>
        <div class="field-label">Preset tags:</div>
        <div class="tag-row">
          @for (tag of presetTags; track tag) {
            <span class="tag-chip preset" [class.selected]="selectedTags.includes(tag)" [ngStyle]="selectedTags.includes(tag)?getTagStyle(tag):{'background':'transparent','color':'var(--muted)','border-color':'var(--border)'}" (click)="togglePresetTag(tag)">{{tag}}</span>
          }
        </div>
        <div class="bind-row" style="margin-top:8px">
          <input class="input" [(ngModel)]="customTag" placeholder="Custom tag" (keyup.enter)="addCustomTag()" style="flex:1">
          <button class="btn btn-ghost btn-sm" (click)="addCustomTag()">Add</button>
        </div>
        <button class="btn btn-primary" style="width:100%;margin-top:12px" (click)="saveNotes()">Save</button>
      </div></div>
    }

    @if (editingService) {
      <div class="modal-overlay" (click)="editingService=null"><div class="modal" (click)="$event.stopPropagation()" style="width:440px">
        <div class="modal-head">
          <div style="display:flex;align-items:center;gap:8px">
            <span class="material-icons" style="font-size:22px;color:var(--accent)">shield</span>
            <b>Auto-start on Boot</b>
          </div>
          <button class="btn btn-ghost btn-sm" (click)="editingService=null"><span class="material-icons" style="font-size:18px">close</span></button>
        </div>

        <div style="margin-bottom:14px">
          <div style="font-weight:600;font-size:13px">{{editingService.hostname||editingService.name||editingService.tunnelId}}</div>
          <div class="mono muted" style="font-size:11px;margin-top:2px">ID: {{editingService.tunnelId}}</div>
        </div>

        @if (api.daemonRunning()) {
          <div style="display:flex;align-items:flex-start;gap:8px;padding:10px 12px;background:rgba(74,222,128,0.1);border:1px solid rgba(74,222,128,0.25);border-radius:8px;font-size:12px;color:var(--green);margin-bottom:16px">
            <span class="material-icons" style="font-size:18px;flex-shrink:0;margin-top:1px">check_circle</span>
            <div>
              <b>Daemon is running</b>
              <div style="font-size:11px;opacity:0.9;margin-top:2px">Auto-started tunnels launch automatically when the system boots and whenever the background daemon starts.</div>
            </div>
          </div>
        } @else {
          <div style="display:flex;align-items:flex-start;gap:8px;padding:10px 12px;background:rgba(248,113,113,0.1);border:1px solid rgba(248,113,113,0.25);border-radius:8px;font-size:12px;color:var(--red);margin-bottom:16px">
            <span class="material-icons" style="font-size:18px;flex-shrink:0;margin-top:1px">error</span>
            <div>
              <b>Daemon is stopped</b>
              <div style="font-size:11px;opacity:0.9;margin-top:2px">The background daemon is currently offline. Start the daemon for auto-start to take effect.</div>
            </div>
          </div>
        }

        <div style="display:flex;align-items:center;justify-content:space-between;padding:12px;background:var(--bg);border:1px solid var(--border);border-radius:8px;margin-bottom:16px">
          <div>
            <div style="font-weight:600;font-size:14px">Auto-start on boot</div>
            <div style="font-size:11px;color:var(--muted);margin-top:2px">
              {{serviceModalEnabled ? 'Tunnel will auto-start with background daemon' : 'Tunnel must be started manually'}}
            </div>
          </div>
          <label class="switch">
            <input type="checkbox" [(ngModel)]="serviceModalEnabled">
            <span></span>
          </label>
        </div>

        <div style="margin-bottom:16px">
          <label class="field-label">Target Local Port (required for forwarding traffic)</label>
          <input class="input" type="number" [(ngModel)]="serviceModalPort" placeholder="e.g. 8080" style="width:100%">
        </div>

        <p style="font-size:11px;color:var(--muted);margin-bottom:16px;line-height:1.4">
          Requires the background daemon to be installed (see Settings). Without it, this flag has no effect.
        </p>

        <div class="bind-row" style="justify-content:flex-end">
          <button class="btn btn-ghost btn-sm" (click)="editingService=null">Cancel</button>
          <button class="btn btn-primary btn-sm" (click)="saveServiceModal()">Save Configuration</button>
        </div>
      </div></div>
    }

    @if (logsModal()) {
      <div class="modal-overlay" (click)="logsModal.set(false)"><div class="modal" (click)="$event.stopPropagation()"><div class="modal-head"><b>Logs</b><button class="btn btn-ghost btn-sm" (click)="logsModal.set(false)"><span class="material-icons" style="font-size:18px">close</span></button></div><div class="log-body">
        @if (logLines().length === 0) { <div class="muted">No logs</div> }
        @for (l of logLines(); track $index) { <div class="mono">{{l}}</div> }
      </div></div></div>
    }
  `,
})
export class DashboardComponent implements OnInit, OnDestroy {
  public api = inject(ApiService);
  private toast = inject(ToastService);
  private modals = inject(ModalService);
  private confirmSvc = inject(ConfirmService);
  private destroyRef = inject(DestroyRef);
  loading = signal(false);
  error = signal('');
  tunnels = signal<Tunnel[]>([]);
  runningCount = computed(() => this.tunnels().filter(t=>t.state==='running').length);
  crashedCount = computed(() => this.tunnels().filter(t=>t.state==='crashed').length);
  stoppedCount = computed(() => this.tunnels().filter(t=>t.state==='stopped'||t.state==='inactive').length);
  zones = signal<DnsZone[]>([]);
  showBind = false; bind = {subdomain:'',zoneId:'',port:0,protocol:'http',serviceEnabled:false};
  bindPort = 0; bindProtocol = 'http'; bindTunnelId = '';
  logsModal = signal(false); logLines = signal<string[]>([]);
  actingTunnelId = signal('');
  editingNotes: string|null = null; notesText = ''; selectedTags: string[] = []; customTag = '';
  editingService: Tunnel|null = null; serviceModalEnabled = false; serviceModalPort = 0;
  presetTags = ['prod','staging','dev','api','internal','testing','monitoring','backend','frontend','database','auth','webhook'];
  private _tagColors: Record<string,string> = {
    prod:'#E53935',production:'#E53935',staging:'#FF8F00',dev:'#42A5F5',development:'#42A5F5',
    api:'#7C4DFF',internal:'#00ACC1',testing:'#43A047',monitoring:'#FDD835',backend:'#1E88E5',
    frontend:'#43A047',database:'#8E24AA',auth:'#E53935',webhook:'#FF8F00',
  };

  private _init = effect(() => {
    this.api.eventCount();
    this.refreshTunnels();
  });

  ngOnInit() { this.refreshAll(); this.destroyRef.onDestroy(() => this._init.destroy()); }
  ngOnDestroy() {}

  async refreshAll() { this.loading.set(true); this.error.set(''); try { await this.refreshTunnels(); await this._loadZones(); await this.api.checkCloudflared(); } catch {} finally { this.loading.set(false); } }
  async refreshTunnels() { try { const r = await this.api.call('/api/tunnels/all'); this.tunnels.set(r.tunnels||[]); } catch(e:any) { this.error.set(e.error||'Connection failed'); this.tunnels.set([]); }}
  async _loadZones() { try { const r = await this.api.call('/api/zones'); this.zones.set(r.zones||[]); } catch {} }

  async recheckCloudflared() {
    this.toast.show('Checking cloudflared...');
    const res = await this.api.checkCloudflared(true);
    if (res.installed) {
      this.toast.show('cloudflared detected: ' + (res.path || 'installed'));
    } else {
      this.toast.show('cloudflared is not installed!', true);
    }
  }

  stateClass(s:string) { return s==='running'?'badge-green':s==='crashed'?'badge-red':s==='starting'?'badge-yellow':s==='inactive'?'badge-gray':'badge-gray'; }
  extractPort(s?:string) { if(!s)return null; const m=s.match(/:(\d+)$/); return m?+m[1]:null; }
  getTagStyle(tag:string) { const c = this._tagColors[tag.toLowerCase()] || '#6366F1'; return {'background': c+'26', 'color': c, 'border-color': c+'66'}; }
  splitTags(tags?:string): string[] { return (tags||'').split(',').map(t=>t.trim()).filter(t=>t.length>0); }

  onPortChange(val: any) {
    const p = +val;
    if (p === 22 || p === 2222) {
      this.bind.protocol = 'ssh';
    } else if (p === 443 || p === 8443) {
      this.bind.protocol = 'https';
    } else if (p === 3389) {
      this.bind.protocol = 'rdp';
    }
  }

  getProto(t: Tunnel): string {
    if (t.protocol) return t.protocol.toLowerCase();
    if (t.service) {
      const idx = t.service.indexOf('://');
      if (idx !== -1) return t.service.substring(0, idx).toLowerCase();
    }
    const p = t.port || this.extractPort(t.service);
    if (p === 22 || p === 2222) return 'ssh';
    if (p === 443 || p === 8443) return 'https';
    if (p === 3389) return 'rdp';
    return 'http';
  }

  tunnelUrl(t: Tunnel): string {
    const proto = this.getProto(t);
    const host = t.hostname || '';
    if (!host) return '';
    if (proto === 'ssh') return 'ssh://' + host;
    if (proto === 'rdp') return 'rdp://' + host;
    if (proto === 'tcp') return 'tcp://' + host;
    return 'https://' + host;
  }

  async copySsh(hostname?: string) {
    if (!hostname) return;
    const cmd = `ssh ${hostname}`;
    try {
      await navigator.clipboard.writeText(cmd);
      this.toast.show(`Copied: ${cmd} (ensure ~/.ssh/config has ProxyCommand cloudflared)`);
    } catch {
      this.toast.show('Copy failed', true);
    }
  }

  startBindExisting(t: Tunnel) {
    this.bindTunnelId = t.tunnelId;
    this.bindPort = t.port || this.extractPort(t.service) || 0;
    this.bindProtocol = this.getProto(t);
  }

  async quickBind() {
    if (this.api.cloudflared() && !this.api.cloudflared()?.installed) {
      return this.toast.show('cloudflared is not installed!', true);
    }
    const z = this.zones().find(x=>x.id===this.bind.zoneId);
    if(!this.bind.subdomain||!this.bind.zoneId||!this.bind.port||!z) return this.toast.show('All fields required',true);
    this.loading.set(true);
    try {
      const r = await this.api.call('/api/bind','POST',{
        subdomain:this.bind.subdomain,
        zoneId:this.bind.zoneId,
        zoneName:z.name,
        port:+this.bind.port,
        protocol:this.bind.protocol || 'http',
        serviceEnabled:!!this.bind.serviceEnabled,
      });
      this.toast.show('Bound: '+r.url + (this.bind.serviceEnabled ? ' (Auto-start enabled)' : ''));
      this.showBind=false;
      this.bind = {subdomain:'',zoneId:'',port:0,protocol:'http',serviceEnabled:false};
      this.refreshTunnels();
    } catch(e:any) {
      this.toast.show('Bind failed: '+(e.error||e.message),true);
    } finally {
      this.loading.set(false);
    }
  }

  openServiceModal(t: Tunnel) {
    this.editingService = t;
    this.serviceModalEnabled = !!t.serviceEnabled;
    this.serviceModalPort = t.port || this.extractPort(t.service) || 0;
  }

  async saveServiceModal() {
    if (!this.editingService) return;
    const tunnel = this.editingService;
    const enabled = this.serviceModalEnabled;
    const port = +this.serviceModalPort || undefined;
    this.loading.set(true);
    try {
      await this.api.toggleTunnelService(tunnel.tunnelId, enabled, port, tunnel.hostname);
      this.toast.show(enabled ? `Auto-start enabled for ${tunnel.hostname || tunnel.tunnelId}` : `Auto-start disabled for ${tunnel.hostname || tunnel.tunnelId}`);
      this.editingService = null;
      this.refreshTunnels();
    } catch {
      this.toast.show('Failed to update auto-start configuration', true);
    } finally {
      this.loading.set(false);
    }
  }
  async quickBindExisting(tunnelId:string) {
    if (this.api.cloudflared() && !this.api.cloudflared()?.installed) {
      return this.toast.show('cloudflared is not installed!', true);
    }
    if(this.actingTunnelId())return; this.actingTunnelId.set(tunnelId); this.loading.set(true); try { await this.api.call('/api/tunnels/'+tunnelId+'/bind','POST',{port:this.bindPort||undefined,protocol:this.bindProtocol||'http'}); this.toast.show('Tunnel bound'); this.bindTunnelId=''; this.refreshTunnels(); } catch(e:any) { this.toast.show('Bind failed: '+(e.error||e.message),true); } finally { this.loading.set(false); this.actingTunnelId.set(''); }}
  async unbind(id:string) { if(this.actingTunnelId())return; if(!await this.confirmSvc.confirm('Unbind?'))return; this.actingTunnelId.set(id); try{await this.api.call('/api/tunnels/'+id,'DELETE');this.toast.show('Unbound');this.refreshTunnels();}catch{this.toast.show('Error',true);}finally{this.actingTunnelId.set('');}}
  async deleteTunnel(id:string) { if(this.actingTunnelId())return; if(!await this.confirmSvc.confirm('Delete from Cloudflare?'))return; this.actingTunnelId.set(id); try{await this.api.call('/api/tunnels/'+id+'/delete','POST');this.toast.show('Deleted');this.refreshTunnels();}catch{this.toast.show('Error',true);}finally{this.actingTunnelId.set('');}}
  async showLogs(id:string) { this.logsModal.set(true); this.logLines.set([]); this.actingTunnelId.set(id); try{const r=await this.api.call('/api/logs/'+id+'?limit=100');this.logLines.set(r.logs||[]);}catch{this.logLines.set(['Error']);}finally{this.actingTunnelId.set('');}}
  async copyUrl(url:string) { try{await navigator.clipboard.writeText(url);this.toast.show('Copied!');}catch{this.toast.show('Copy failed',true);}}
  async showQr(url:string) { this.modals.kind.set('qr'); this.modals.qrData.set(url); try { this.modals.qrDataUrl.set(await QRCode.toDataURL(url,{width:240,margin:2,color:{dark:'#0F172A',light:'#ffffff'}})); } catch { this.modals.qrDataUrl.set(''); } }
  async toggleService(tunnelId:string,hostname:string) { if(this.actingTunnelId())return; this.actingTunnelId.set(tunnelId); this.loading.set(true); try { const t = this.tunnels().find(x=>x.tunnelId===tunnelId); const v = !(t?.serviceEnabled); await this.api.call('/api/tunnels/'+tunnelId+'/service','PUT',{enabled:v}); this.toast.show(v?'Auto-start enabled for '+hostname:'Auto-start disabled'); this.refreshTunnels(); } catch { this.toast.show('Error',true); } finally { this.loading.set(false); this.actingTunnelId.set(''); }}
  async saveNotes() { if(!this.editingNotes)return; this.loading.set(true); try { await this.api.call('/api/tunnels/'+this.editingNotes+'/notes','PUT',{notes:this.notesText,tags:this.selectedTags.join(',')}); this.toast.show('Saved'); this.editingNotes=null; this.refreshTunnels(); } catch { this.toast.show('Error',true); } finally { this.loading.set(false); }}
  togglePresetTag(tag:string) { const i=this.selectedTags.indexOf(tag); if(i>=0) this.selectedTags.splice(i,1); else { if(this.selectedTags.length>=5) return this.toast.show('Max 5 tags',true); this.selectedTags.push(tag); } this.selectedTags=[...this.selectedTags]; }
  addCustomTag() { const t=this.customTag.trim(); if(!t) return; if(this.selectedTags.length>=5) return this.toast.show('Max 5 tags',true); if(!this.selectedTags.includes(t)) this.selectedTags=[...this.selectedTags,t]; this.customTag=''; }
  removeTag(tag:string) { this.selectedTags=this.selectedTags.filter(t=>t!==tag); }
}
