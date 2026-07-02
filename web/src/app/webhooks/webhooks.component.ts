import { Component, OnInit, signal, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';

interface WebhookConfig { id: string; name: string; type: string; enabled: boolean; triggers: string[]; url?: string; }

@Component({
  selector: 'app-webhooks',
  standalone: true,
  imports: [FormsModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Webhooks</h1><button class="btn btn-primary btn-sm" (click)="showWForm=true">+ New</button></div>
    @if (showWForm) { <div class="card"><div class="bind-row"><input class="input" [(ngModel)]="wForm.name" placeholder="Name"><input class="input" [(ngModel)]="wForm.url" placeholder="URL"><button class="btn btn-primary btn-sm" (click)="saveWebhook()">Save</button><button class="btn btn-ghost btn-sm" (click)="showWForm=false">Cancel</button></div></div> }
    @if (hooks().length === 0) { <div class="empty">No webhooks</div> }
    @for (w of hooks(); track w.id) {
      <div class="card hook-row"><div class="hook-info"><b>{{w.name}}</b><span class="badge badge-gray">{{w.type}}</span><span class="muted text-xs">{{(w.triggers||[]).join(', ')||'no triggers'}}</span></div><div class="action-cell"><button class="btn btn-ghost btn-xs" (click)="testWebhook(w.id)">Test</button><button class="btn btn-ghost btn-xs" (click)="delWebhook(w.id)">Del</button></div></div>
    }
  `,
})
export class WebhooksComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  loading = signal(false);
  hooks = signal<WebhookConfig[]>([]);
  showWForm = false; wForm = {name:'',url:'',type:'http'};

  ngOnInit() { this.loadWebhooks(); }

  async loadWebhooks() { this.loading.set(true); try { const r = await this.api.call('/api/webhooks'); this.hooks.set(r.webhooks||[]); } catch {} finally { this.loading.set(false); } }
  async saveWebhook() { this.loading.set(true); try { await this.api.call('/api/webhooks','POST',this.wForm); this.showWForm=false; this.wForm = {name:'',url:'',type:'http'}; await this.loadWebhooks(); this.toast.show('Created'); } catch { this.toast.show('Error',true); this.loading.set(false); } }
  async testWebhook(id:string) { this.loading.set(true); try { await this.api.call('/api/webhooks/'+id+'/test','POST'); this.toast.show('Test passed'); } catch { this.toast.show('Test failed',true); } finally { this.loading.set(false); } }
  async delWebhook(id:string) { if(!confirm('Delete?')) return; this.loading.set(true); try { await this.api.call('/api/webhooks/'+id,'DELETE'); await this.loadWebhooks(); this.toast.show('Deleted'); } catch { this.toast.show('Error',true); this.loading.set(false); } }
}
