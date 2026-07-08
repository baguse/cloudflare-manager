import { Component, OnInit, signal, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';
import { ConfirmService } from '../confirm.service';
import { CommonModule } from '@angular/common';

interface RateAlert { id: string; name: string; domain: string; thresholdPerHour: number; enabled: boolean; webhookId?: string; lastCheckedAt?: string; lastRequestCount?: number; lastTriggeredAt?: string; }

@Component({
  selector: 'app-alerts',
  standalone: true,
  imports: [FormsModule, CommonModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Rate Alerts</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="checkAlerts()">Check Now</button><button class="btn btn-primary btn-sm" (click)="openForm()">+ New</button></div></div>

    @if (showForm) {
      <div class="modal-overlay" (click)="closeForm()"><div class="modal" (click)="$event.stopPropagation()" style="width:440px">
        <div class="modal-head"><span class="material-icons" style="font-size:20px;color:var(--accent)">speed</span><b>{{editId?'Edit Alert':'New Alert'}}</b><button class="btn btn-ghost btn-sm" (click)="closeForm()"><span class="material-icons" style="font-size:18px">close</span></button></div>
        <input class="input" [(ngModel)]="form.name" placeholder="Name" style="width:100%;margin-top:12px">
        <input class="input" [(ngModel)]="form.domain" placeholder="Domain (e.g. example.com)" style="width:100%;margin-top:8px">
        <input class="input" [(ngModel)]="form.thresholdPerHour" type="number" min="1" placeholder="Threshold per hour" style="width:100%;margin-top:8px">
        <div class="setting-row" style="margin-top:8px"><span>Enabled</span><label class="switch"><input type="checkbox" [(ngModel)]="form.enabled"><span></span></label></div>
        <div class="setting-row"><span>Notify via webhook</span><select class="input" [(ngModel)]="form.webhookId" style="width:200px"><option value="">None</option><option *ngFor="let w of webhooks()" [value]="w.id">{{w.name}}</option></select></div>
        <div class="bind-row" style="margin-top:16px;justify-content:flex-end">
          <button class="btn btn-ghost btn-sm" (click)="closeForm()">Cancel</button>
          <button class="btn btn-primary btn-sm" (click)="saveAlert()">{{editId?'Update':'Create'}}</button>
        </div>
      </div></div>
    }

    @if (checkResults) {
      <div class="card" style="margin-bottom:12px">
        <div class="modal-head" style="margin-bottom:0"><span class="material-icons" style="font-size:20px;color:var(--accent)">analytics</span><b>Check Results</b><button class="btn btn-ghost btn-sm" (click)="checkResults=null"><span class="material-icons" style="font-size:18px">close</span></button></div>
        <div class="muted text-xs" style="margin-top:4px">Checked at {{checkTime}}</div>
        @for (r of checkResults; track r.id) {
          <div class="hook-row" style="padding:4px 0;border-bottom:1px solid var(--border)">
            <b>{{r.name}}</b>
            <span [style.color]="r.exceeded?'var(--red)':'var(--green)'" style="font-size:13px">{{r.requests||0}} req/h {{r.exceeded?'⚠ exceeds '+r.threshold+'/h':''}}</span>
          </div>
        }
      </div>
    }

    @if (alerts().length === 0) { <div class="empty">No alerts configured</div> }
    @for (a of alerts(); track a.id) {
      <div class="card hook-row">
        <div>
          <b>{{a.name}}</b>
          <span class="badge" [ngClass]="a.enabled!==false?'badge-green':'badge-gray'" style="margin-left:6px">{{a.enabled!==false?'ACTIVE':'PAUSED'}}</span>
          <span class="muted text-xs" style="margin-left:4px">{{a.domain}} · {{a.thresholdPerHour | number}}/hr</span>
          @if (a.lastCheckedAt) { <span class="muted" style="font-size:10px;margin-left:4px">Last: {{a.lastRequestCount}} req/h</span> }
        </div>
        <div class="action-cell">
          <button class="btn btn-ghost btn-xs" (click)="toggleEnabled(a)">{{a.enabled!==false?'Pause':'Resume'}}</button>
          <button class="btn btn-ghost btn-xs" (click)="editAlert(a)"><span class="material-icons" style="font-size:14px">edit</span></button>
          <button class="btn btn-ghost btn-xs danger" (click)="delAlert(a.id)"><span class="material-icons" style="font-size:14px">delete_outline</span></button>
        </div>
      </div>
    }
  `,
})
export class AlertsComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  private confirmSvc = inject(ConfirmService);
  loading = signal(false);
  alerts = signal<RateAlert[]>([]);
  webhooks = signal<any[]>([]);
  showForm = false; editId = '';
  form: any = {};
  checkResults: any = null; checkTime = '';

  ngOnInit() { this.loadAll(); }

  emptyForm() { return {name:'',domain:'',thresholdPerHour:10000,enabled:true,webhookId:''}; }

  async loadAll() {
    this.loading.set(true);
    try {
      const [a, w] = await Promise.all([this.api.call('/api/rate-alerts'), this.api.call('/api/webhooks')]);
      this.alerts.set(a.alerts||[]); this.webhooks.set(w.webhooks||[]);
    } catch {}
    this.loading.set(false);
  }

  openForm() { this.form = this.emptyForm(); this.editId = ''; this.showForm = true; }
  closeForm() { this.showForm = false; this.editId = ''; }
  editAlert(a: RateAlert) { this.editId = a.id; this.form = {name:a.name,domain:a.domain,thresholdPerHour:a.thresholdPerHour,enabled:a.enabled!==false,webhookId:a.webhookId||''}; this.showForm = true; }

  async saveAlert() {
    if (!this.form.name || !this.form.domain || !this.form.thresholdPerHour) return this.toast.show('All fields required', true);
    this.loading.set(true);
    try {
      const body: any = {name:this.form.name, domain:this.form.domain, thresholdPerHour:+this.form.thresholdPerHour, enabled:this.form.enabled, webhookId:this.form.webhookId||undefined};
      if (this.editId) { await this.api.call('/api/rate-alerts/'+this.editId,'PUT',body); this.toast.show('Updated'); }
      else { await this.api.call('/api/rate-alerts','POST',body); this.toast.show('Created'); }
      this.closeForm();
      await this.loadAll();
    } catch(e:any) { this.toast.show(e.error||'Error', true); }
    this.loading.set(false);
  }

  async toggleEnabled(a: RateAlert) {
    this.loading.set(true);
    try {
      await this.api.call('/api/rate-alerts/'+a.id,'PUT',{name:a.name,domain:a.domain,thresholdPerHour:a.thresholdPerHour,enabled:!(a.enabled!==false),webhookId:a.webhookId});
      await this.loadAll();
    } catch { this.toast.show('Error', true); }
    this.loading.set(false);
  }

  async checkAlerts() {
    this.loading.set(true);
    try {
      const r = await this.api.call('/api/rate-alerts/check','POST');
      this.checkTime = new Date().toLocaleTimeString();
      if (r.results && typeof r.results === 'object') {
        this.checkResults = Object.entries(r.results).map(([id, v]:[string,any]) => ({id, name:v.name||id, requests:v.requests||0, threshold:v.threshold||0, exceeded:(v.requests||0) > (v.threshold||0)}));
      } else {
        this.checkResults = [];
      }
    } catch { this.toast.show('Check failed', true); }
    this.loading.set(false);
    await this.loadAll();
  }

  async delAlert(id: string) { if(!await this.confirmSvc.confirm('Delete this alert?')) return; this.loading.set(true); try { await this.api.call('/api/rate-alerts/'+id,'DELETE'); this.toast.show('Deleted'); await this.loadAll(); } catch { this.toast.show('Error', true); } finally { this.loading.set(false); } }
}
