import { Component, OnInit, signal, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';
import { ConfirmService } from '../confirm.service';

interface DnsZone { id: string; name: string; }
interface DnsRecord { id: string; type: string; name: string; content: string; ttl: number; proxied: boolean; }

@Component({
  selector: 'app-dns',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    @if (error()) { <div class="card" style="color:var(--red);text-align:center"><span class="material-icons" style="font-size:20px;vertical-align:middle">error_outline</span> {{error()}} <button class="btn btn-ghost btn-xs" (click)="loadAll()">Retry</button></div> }
    <div class="page-header"><h1>DNS Editor</h1></div>
    <div class="card bind-row">
      <select class="input" [(ngModel)]="dnsZone" (change)="reloadDns()">
        @for (z of zones(); track z.id) { <option [value]="z.name">{{z.name}}</option> }
      </select>
      <button class="btn btn-primary btn-sm" (click)="dnsForm={type:'A',name:'',content:'',ttl:1,proxied:false};editDnsId='';showDnsForm=true">+ New Record</button>
    </div>
    @if (showDnsForm) {
      <div class="card" style="max-width:520px;margin-bottom:16px">
        <div style="display:grid;grid-template-columns:1fr 2fr;gap:12px">
          <div><label class="field-label">Type</label><select class="input" [(ngModel)]="dnsForm.type"><option>A</option><option>AAAA</option><option>CNAME</option><option>TXT</option><option>MX</option><option>NS</option><option>SRV</option></select></div>
          <div><label class="field-label">Name <span style="font-weight:400;color:var(--muted);font-size:11px">(&#64; for root)</span></label><input class="input" [(ngModel)]="dnsForm.name" placeholder="@"></div>
        </div>
        <div style="margin-top:12px"><label class="field-label">Content</label><textarea class="input" [(ngModel)]="dnsForm.content" rows="2" [placeholder]="dnsForm.type==='A'?'192.0.2.1':dnsForm.type==='AAAA'?'2001:db8::1':dnsForm.type==='CNAME'?'target.example.com':''" style="resize:vertical;width:100%;box-sizing:border-box"></textarea></div>
        <div style="display:flex;gap:12px;margin-top:12px">
          <div style="width:80px"><label class="field-label">TTL</label><input class="input" [(ngModel)]="dnsForm.ttl" type="number" placeholder="auto"></div>
          @if (dnsForm.type==='MX') { <div style="width:80px"><label class="field-label">Priority</label><input class="input" [(ngModel)]="dnsForm.priority" type="number" placeholder="10"></div> }
        </div>
        @if (dnsForm.type==='A'||dnsForm.type==='AAAA'||dnsForm.type==='CNAME') {
          <div style="margin-top:12px;display:flex;align-items:center;gap:8px"><label class="switch"><input type="checkbox" [(ngModel)]="dnsForm.proxied"><span></span></label><span style="font-size:13px">Proxied</span></div>
        }
        <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:16px">
          <button class="btn btn-ghost btn-sm" (click)="dnsForm={type:'A',name:'',content:'',ttl:1,proxied:false};editDnsId='';showDnsForm=false">Cancel</button>
          <button class="btn btn-primary btn-sm" (click)="saveDns()">{{editDnsId?'Update':'Save'}}</button>
        </div>
      </div>
    }
    <div class="card">
      @if (records().length > 0) {
        <table><thead><tr><th>Type</th><th>Name</th><th>Content</th><th>TTL</th><th></th><th></th></tr></thead><tbody>
          @for (r of records(); track r.id) {
            <tr><td><span class="badge" [ngClass]="dnsTypeBadge(r.type)">{{r.type}}</span></td><td class="mono">{{r.name}}</td><td class="mono muted">{{r.content}}</td><td>{{r.ttl==1?'auto':r.ttl}}</td><td><span class="badge" [ngClass]="r.proxied?'badge-yellow':'badge-gray'">{{r.proxied?'PROXIED':'DNS only'}}</span></td><td><div class="action-cell">
              <button class="btn btn-ghost btn-xs" (click)="editDns(r)"><span class="material-icons" style="font-size:14px">edit</span></button>
              <button class="btn btn-ghost btn-xs" (click)="deleteDns(r)"><span class="material-icons" style="font-size:14px">delete_outline</span></button>
            </div></td></tr>
          }
        </tbody></table>
      } @else {
        <div class="empty">No records</div>
      }
    </div>
  `,
})
export class DnsComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  private confirmSvc = inject(ConfirmService);
  loading = signal(false);
  error = signal('');
  zones = signal<DnsZone[]>([]);
  records = signal<DnsRecord[]>([]);
  dnsZone = '';
  showDnsForm = false; dnsForm: any = {type:'A',name:'',content:'',ttl:1,proxied:false}; editDnsId = '';

  ngOnInit() { this.loadAll(); }

  async loadAll() {
    this.loading.set(true);
    this.error.set('');
    try {
      const z = await this.api.call('/api/zones');
      const zones: DnsZone[] = z.zones || [];
      this.zones.set(zones);
      if (zones.length) {
        this.dnsZone = zones[0].name;
        await this._fetchDns(zones[0].id);
      }
    } catch (e: any) {
      this.error.set(e.error || 'Connection failed');
    } finally {
      this.loading.set(false);
    }
  }

  async reloadDns() {
    const z = this.zones().find(x => x.name === this.dnsZone);
    if (!z) return;
    this.loading.set(true);
    this.error.set('');
    try { await this._fetchDns(z.id); } catch (e: any) { this.error.set(e.error || 'Connection failed'); } finally { this.loading.set(false); }
  }

  private async _fetchDns(zoneId: string) {
    const r = await this.api.call('/api/dns?zoneId=' + zoneId);
    this.records.set(r.records || []);
  }

  async saveDns() {
    const z = this.zones().find(x => x.name === this.dnsZone);
    if (!z) return;
    const data: any = {zoneId: z.id, type: this.dnsForm.type, name: this.dnsForm.name, content: this.dnsForm.content, ttl: +this.dnsForm.ttl};
    if (this.dnsForm.type === 'MX') data.priority = +(this.dnsForm.priority || 10);
    if (this.dnsForm.type === 'A' || this.dnsForm.type === 'AAAA' || this.dnsForm.type === 'CNAME') data.proxied = !!this.dnsForm.proxied;
    this.loading.set(true);
    try {
      if (this.editDnsId) { data.recordId = this.editDnsId; await this.api.call('/api/dns', 'PUT', data); this.toast.show('Updated'); }
      else { await this.api.call('/api/dns', 'POST', data); this.toast.show('Created'); }
    } catch { this.toast.show('Error', true); this.loading.set(false); return; }
    this.showDnsForm = false;
    this.editDnsId = '';
    this.dnsForm = {type:'A',name:'',content:'',ttl:1,proxied:false};
    await this.reloadDns();
  }

  editDns(r: any) { this.dnsForm = {type: r.type, name: r.name, content: r.content, ttl: r.ttl, proxied: r.proxied || false, priority: r.priority || 10}; this.editDnsId = r.id; this.showDnsForm = true; }
  dnsTypeBadge(t: string) { return t === 'A' ? 'badge-green' : t === 'AAAA' ? 'badge-green' : t === 'CNAME' ? 'badge-yellow' : t === 'TXT' ? 'badge-gray' : t === 'MX' ? 'badge-red' : 'badge-gray'; }
  async deleteDns(r: DnsRecord) {
    if (!await this.confirmSvc.confirm('Delete?')) return;
    const z = this.zones().find(x => x.name === this.dnsZone);
    if (!z) return;
    this.loading.set(true);
    try { await this.api.call('/api/dns', 'DELETE', {zoneId: z.id, recordId: r.id}); this.toast.show('Deleted'); await this.reloadDns(); } catch { this.toast.show('Error', true); this.loading.set(false); }
  }
}
