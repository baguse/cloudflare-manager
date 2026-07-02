import { Component, OnInit, signal, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';

interface RateAlert { id: string; name: string; domain: string; thresholdPerHour: number; enabled: boolean; }

@Component({
  selector: 'app-alerts',
  standalone: true,
  imports: [FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Rate Alerts</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="checkAlerts()">Check Now</button><button class="btn btn-primary btn-sm" (click)="showAForm=true">+ New</button></div></div>
    @if (showAForm) { <div class="card"><div class="bind-row"><input class="input" [(ngModel)]="aForm.name" placeholder="Name"><input class="input" [(ngModel)]="aForm.domain" placeholder="Domain"><input class="input" [(ngModel)]="aForm.thresholdPerHour" placeholder="Threshold/hr" type="number"><button class="btn btn-primary btn-sm" (click)="saveAlert()">Save</button><button class="btn btn-ghost btn-sm" (click)="showAForm=false">Cancel</button></div></div> }
    @if (alerts().length === 0) { <div class="empty">No alerts</div> }
    @for (a of alerts(); track a.id) { <div class="card hook-row"><div><b>{{a.name}}</b><span class="muted text-xs">{{a.domain}} · {{a.thresholdPerHour}}/hr</span></div><button class="btn btn-ghost btn-xs" (click)="delAlert(a.id)">Del</button></div> }
  `,
})
export class AlertsComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  loading = signal(false);
  alerts = signal<RateAlert[]>([]);
  showAForm = false; aForm = {name:'',domain:'',thresholdPerHour:10000};

  ngOnInit() { this.loadAlerts(); }

  async loadAlerts() { this.loading.set(true); try { const r = await this.api.call('/api/rate-alerts'); this.alerts.set(r.alerts||[]); } catch {} finally { this.loading.set(false); } }
  async saveAlert() { try { await this.api.call('/api/rate-alerts','POST',this.aForm); this.showAForm=false; this.loadAlerts(); this.toast.show('Created'); } catch { this.toast.show('Error',true); } }
  async checkAlerts() { try { const r = await this.api.call('/api/rate-alerts/check','POST'); this.toast.show(JSON.stringify(r.results)); } catch { this.toast.show('Error',true); } }
  async delAlert(id:string) { if(!confirm('Delete?')) return; try { await this.api.call('/api/rate-alerts/'+id,'DELETE'); this.loadAlerts(); this.toast.show('Deleted'); } catch { this.toast.show('Error',true); } }
}
