import { Component, OnInit, signal, computed, inject, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ModalService } from '../modal.service';
import { ToastService } from '../toast.service';
import * as QRCode from 'qrcode';

interface Tunnel { tunnelId: string; state: string; hostname: string; port: number; restartCount: number; notes?:string; tags?:string; serviceEnabled?:boolean; service?:string; }
interface DnsZone { id: string; name: string; }

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    @if (error()) { <div class="card" style="color:var(--red);text-align:center"><span class="material-icons" style="font-size:20px;vertical-align:middle">error_outline</span> {{error()}} <button class="btn btn-ghost btn-xs" (click)="refreshAll()">Retry</button></div> }
    <div class="page-header"><h1>Dashboard</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="refreshAll()"><span class="material-icons" style="font-size:16px">refresh</span></button><button class="btn btn-primary btn-sm" (click)="showBind=true">+ Quick Bind</button></div></div>
    @if (showBind) {
      <div class="card bind-row"><input class="input" [(ngModel)]="bind.subdomain" placeholder="Subdomain"><select class="input" [(ngModel)]="bind.zoneId"><option value="">Select domain...</option>
        @for (z of zones(); track z.id) { <option [value]="z.id">{{z.name}}</option> }
      </select><input class="input" [(ngModel)]="bind.port" placeholder="Port" type="number"><button class="btn btn-primary btn-sm" (click)="quickBind()">Bind</button></div>
    }
    <div class="stats-row"><div class="stat"><span class="stat-num">{{tunnels().length}}</span><span class="stat-label">Tunnels</span></div><div class="stat"><span class="stat-num green">{{runningCount()}}</span><span class="stat-label">Running</span></div><div class="stat"><span class="stat-num red">{{crashedCount()}}</span><span class="stat-label">Crashed</span></div><div class="stat"><span class="stat-num muted">{{stoppedCount()}}</span><span class="stat-label">Inactive</span></div></div>
    <div class="card">
      @if (tunnels().length > 0) {
        <table><thead><tr><th>Status</th><th>Hostname</th><th>Port</th><th>Actions</th></tr></thead><tbody>
          @for (t of tunnels(); track t.tunnelId) {
            <tr><td><span class="badge" [ngClass]="stateClass(t.state)">{{t.state}}</span></td>
              <td>{{t.hostname||'-'}}
                @for (tag of splitTags(t.tags); track tag) { <span class="tag-chip" [ngStyle]="getTagStyle(tag)">{{tag}}</span> }
                @if (t.notes) { <span class="note-text" title="{{t.notes}}"><span class="material-icons" style="font-size:12px;color:var(--accent);vertical-align:middle">sticky_note_2</span>{{t.notes}}</span> }
              </td><td class="muted">{{t.port||extractPort(t.service)||'-'}}</td><td><div class="action-cell">
                <button class="btn btn-ghost btn-xs" title="Notes" (click)="editingNotes=t.tunnelId;notesText=t.notes||'';selectedTags=splitTags(t.tags)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">edit_note</span></button>
                @if (t.state!=='inactive') {
                  <button class="btn btn-ghost btn-xs" title="Auto-start" (click)="toggleService(t.tunnelId,t.hostname)" [style.color]="t.serviceEnabled?'var(--green)':''" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">shield</span></button>
                  <button class="btn btn-ghost btn-xs" title="Copy URL" (click)="copyUrl('https://'+(t.hostname||''))" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">content_copy</span></button>
                  <button class="btn btn-ghost btn-xs" title="QR Code" (click)="showQr('https://'+(t.hostname||''))" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">qr_code</span></button>
                  <button class="btn btn-ghost btn-xs" title="Logs" (click)="showLogs(t.tunnelId)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">terminal</span></button>
                  <button class="btn btn-ghost btn-xs" title="Stop" (click)="unbind(t.tunnelId)" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">stop_circle</span></button>
                } @else {
                  <button class="btn btn-ghost btn-xs" title="QR Code" (click)="showQr('https://'+(t.hostname||''))" [disabled]="actingTunnelId()==t.tunnelId"><span class="material-icons" style="font-size:16px">qr_code</span></button>
                  @if (bindTunnelId===t.tunnelId) {
                    <input class="input" type="number" [(ngModel)]="bindPort" placeholder="Port" style="width:60px;padding:2px 6px;font-size:11px" (keyup.enter)="quickBindExisting(t.tunnelId)">
                    <button class="btn btn-primary btn-xs" (click)="quickBindExisting(t.tunnelId)">Go</button>
                  } @else {
                    <button class="btn btn-primary btn-xs" (click)="bindTunnelId=t.tunnelId;bindPort=extractPort(t.service)||0" [disabled]="actingTunnelId()==t.tunnelId">Bind</button>
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

    @if (logsModal()) {
      <div class="modal-overlay" (click)="logsModal.set(false)"><div class="modal" (click)="$event.stopPropagation()"><div class="modal-head"><b>Logs</b><button class="btn btn-ghost btn-sm" (click)="logsModal.set(false)"><span class="material-icons" style="font-size:18px">close</span></button></div><div class="log-body">
        @if (logLines().length === 0) { <div class="muted">No logs</div> }
        @for (l of logLines(); track $index) { <div class="mono">{{l}}</div> }
      </div></div></div>
    }
  `,
})
export class DashboardComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  private modals = inject(ModalService);
  loading = signal(false);
  error = signal('');
  tunnels = signal<Tunnel[]>([]);
  runningCount = computed(() => this.tunnels().filter(t=>t.state==='running').length);
  crashedCount = computed(() => this.tunnels().filter(t=>t.state==='crashed').length);
  stoppedCount = computed(() => this.tunnels().filter(t=>t.state==='stopped'||t.state==='inactive').length);
  zones = signal<DnsZone[]>([]);
  showBind = false; bind = {subdomain:'',zoneId:'',port:0};
  bindPort = 0; bindTunnelId = '';
  logsModal = signal(false); logLines = signal<string[]>([]);
  actingTunnelId = signal('');
  editingNotes: string|null = null; notesText = ''; selectedTags: string[] = []; customTag = '';
  presetTags = ['prod','staging','dev','api','internal','testing','monitoring','backend','frontend','database','auth','webhook'];
  private _tagColors: Record<string,string> = {
    prod:'#E53935',production:'#E53935',staging:'#FF8F00',dev:'#42A5F5',development:'#42A5F5',
    api:'#7C4DFF',internal:'#00ACC1',testing:'#43A047',monitoring:'#FDD835',backend:'#1E88E5',
    frontend:'#43A047',database:'#8E24AA',auth:'#E53935',webhook:'#FF8F00',
  };

  private _init = effect(() => {
    this.api.eventCount(); // track
    this.refreshTunnels();
  });

  ngOnInit() { this.refreshAll(); }

  async refreshAll() { this.loading.set(true); this.error.set(''); try { await this.refreshTunnels(); await this._loadZones(); } catch {} finally { this.loading.set(false); } }
  async refreshTunnels() { try { const r = await this.api.call('/api/tunnels/all'); this.tunnels.set(r.tunnels||[]); } catch(e:any) { this.error.set(e.error||'Connection failed'); this.tunnels.set([]); }}
  async _loadZones() { try { const r = await this.api.call('/api/zones'); this.zones.set(r.zones||[]); } catch {} }

  stateClass(s:string) { return s==='running'?'badge-green':s==='crashed'?'badge-red':s==='starting'?'badge-yellow':s==='inactive'?'badge-gray':'badge-gray'; }
  extractPort(s?:string) { if(!s)return null; const m=s.match(/:(\d+)$/); return m?+m[1]:null; }
  getTagStyle(tag:string) { const c = this._tagColors[tag.toLowerCase()] || '#6366F1'; return {'background': c+'26', 'color': c, 'border-color': c+'66'}; }
  splitTags(tags?:string): string[] { return (tags||'').split(',').map(t=>t.trim()).filter(t=>t.length>0); }

  async quickBind() {
    const z = this.zones().find(x=>x.id===this.bind.zoneId);
    if(!this.bind.subdomain||!this.bind.zoneId||!this.bind.port||!z) return this.toast.show('All fields required',true);
    this.loading.set(true); try { const r = await this.api.call('/api/bind','POST',{subdomain:this.bind.subdomain,zoneId:this.bind.zoneId,zoneName:z.name,port:+this.bind.port}); this.toast.show('Bound: '+r.url); this.showBind=false; this.refreshTunnels(); } catch(e:any) { this.toast.show('Bind failed: '+(e.error||e.message),true); } finally { this.loading.set(false); }
  }
  async quickBindExisting(tunnelId:string) { if(this.actingTunnelId())return; this.actingTunnelId.set(tunnelId); this.loading.set(true); try { await this.api.call('/api/tunnels/'+tunnelId+'/bind','POST',{port:this.bindPort||undefined}); this.toast.show('Tunnel bound'); this.bindTunnelId=''; this.refreshTunnels(); } catch(e:any) { this.toast.show('Bind failed: '+(e.error||e.message),true); } finally { this.loading.set(false); this.actingTunnelId.set(''); }}
  async unbind(id:string) { if(this.actingTunnelId())return; if(!confirm('Unbind?'))return; this.actingTunnelId.set(id); try{await this.api.call('/api/tunnels/'+id,'DELETE');this.toast.show('Unbound');this.refreshTunnels();}catch{this.toast.show('Error',true);}finally{this.actingTunnelId.set('');}}
  async deleteTunnel(id:string) { if(this.actingTunnelId())return; if(!confirm('Delete from Cloudflare?'))return; this.actingTunnelId.set(id); try{await this.api.call('/api/tunnels/'+id+'/delete','POST');this.toast.show('Deleted');this.refreshTunnels();}catch{this.toast.show('Error',true);}finally{this.actingTunnelId.set('');}}
  async showLogs(id:string) { this.logsModal.set(true); this.logLines.set([]); this.actingTunnelId.set(id); try{const r=await this.api.call('/api/logs/'+id+'?limit=100');this.logLines.set(r.logs||[]);}catch{this.logLines.set(['Error']);}finally{this.actingTunnelId.set('');}}
  async copyUrl(url:string) { try{await navigator.clipboard.writeText(url);this.toast.show('Copied!');}catch{this.toast.show('Copy failed',true);}}
  async showQr(url:string) { this.modals.kind.set('qr'); this.modals.qrData.set(url); try { this.modals.qrDataUrl.set(await QRCode.toDataURL(url,{width:240,margin:2,color:{dark:'#0F172A',light:'#ffffff'}})); } catch { this.modals.qrDataUrl.set(''); } }
  async toggleService(tunnelId:string,hostname:string) { if(this.actingTunnelId())return; this.actingTunnelId.set(tunnelId); this.loading.set(true); try { const t = this.tunnels().find(x=>x.tunnelId===tunnelId); const v = !(t?.serviceEnabled); await this.api.call('/api/tunnels/'+tunnelId+'/service','PUT',{enabled:v}); this.toast.show(v?'Auto-start enabled for '+hostname:'Auto-start disabled'); this.refreshTunnels(); } catch { this.toast.show('Error',true); } finally { this.loading.set(false); this.actingTunnelId.set(''); }}
  async saveNotes() { if(!this.editingNotes)return; this.loading.set(true); try { await this.api.call('/api/tunnels/'+this.editingNotes+'/notes','PUT',{notes:this.notesText,tags:this.selectedTags.join(',')}); this.toast.show('Saved'); this.editingNotes=null; this.refreshTunnels(); } catch { this.toast.show('Error',true); } finally { this.loading.set(false); }}
  togglePresetTag(tag:string) { const i=this.selectedTags.indexOf(tag); if(i>=0) this.selectedTags.splice(i,1); else { if(this.selectedTags.length>=5) return this.toast.show('Max 5 tags',true); this.selectedTags.push(tag); } this.selectedTags=[...this.selectedTags]; }
  addCustomTag() { const t=this.customTag.trim(); if(!t) return; if(this.selectedTags.length>=5) return this.toast.show('Max 5 tags',true); if(!this.selectedTags.includes(t)) this.selectedTags=[...this.selectedTags,t]; this.customTag=''; }
  removeTag(tag:string) { this.selectedTags=this.selectedTags.filter(t=>t!==tag); }
}
