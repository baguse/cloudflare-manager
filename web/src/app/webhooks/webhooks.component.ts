import { Component, OnInit, signal, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { CommonModule } from '@angular/common';
import { ApiService } from '../api.service';
import { ToastService } from '../toast.service';

interface WebhookConfig { id: string; name: string; type: string; enabled: boolean; triggers: string[]; url?: string; method?: string; headers?: Record<string,string>; bodyTemplate?: string; webhookUrl?: string; channelId?: string; botToken?: string; maxRetries?: number; }

const ALL_TRIGGERS = [
  { key: 'tunnelStarted', label: 'Tunnel Started' },
  { key: 'tunnelStopped', label: 'Tunnel Stopped' },
  { key: 'tunnelCrashed', label: 'Tunnel Crashed' },
  { key: 'tunnelCreated', label: 'Tunnel Created' },
  { key: 'tunnelDeleted', label: 'Tunnel Deleted' },
  { key: 'tunnelReconnected', label: 'Tunnel Reconnected' },
  { key: 'daemonStarted', label: 'Daemon Started' },
  { key: 'daemonStopping', label: 'Daemon Stopping' },
  { key: 'rateAlert', label: 'Rate Alert' },
];

@Component({
  selector: 'app-webhooks',
  standalone: true,
  imports: [FormsModule, CommonModule],
  template: `
    @if (loading()) { <div class="loading-bar"></div> }
    <div class="page-header"><h1>Webhooks</h1><div class="actions"><button class="btn btn-ghost btn-sm" (click)="loadWebhooks()"><span class="material-icons" style="font-size:16px">refresh</span></button><button class="btn btn-primary btn-sm" (click)="openForm()">+ New</button></div></div>

    @if (showForm) {
      <div class="modal-overlay" (click)="closeForm()"><div class="modal" (click)="$event.stopPropagation()" style="max-width:540px">
        <div class="modal-head"><span class="material-icons" style="font-size:20px;color:var(--accent)">webhook</span><b>{{editId?'Edit Webhook':'New Webhook'}}</b><button class="btn btn-ghost btn-sm" (click)="closeForm()"><span class="material-icons" style="font-size:18px">close</span></button></div>
        <div class="bind-row" style="margin-top:12px"><input class="input" [(ngModel)]="form.name" placeholder="Name" style="flex:1"></div>

        <div class="bind-row" style="margin-top:12px">
          <select class="input" [(ngModel)]="form.type" (change)="onTypeChange()" style="width:140px">
            <option value="http">HTTP</option>
            <option value="slack">Slack</option>
            <option value="discord">Discord</option>
            <option value="telegram">Telegram</option>
          </select>
          <label class="switch" style="margin-left:16px"><input type="checkbox" [(ngModel)]="form.enabled"><span></span></label>
          <span style="font-size:13px">{{form.enabled?'Enabled':'Disabled'}}</span>
        </div>

        @if (form.type==='http') {
          <input class="input" [(ngModel)]="form.url" placeholder="URL (e.g. https://example.com/webhook)" style="width:100%;margin-top:12px">
          <div class="bind-row" style="margin-top:12px">
            <select class="input" [(ngModel)]="form.method" style="width:120px">
              <option value="POST">POST</option>
              <option value="GET">GET</option>
              <option value="PUT">PUT</option>
              <option value="PATCH">PATCH</option>
              <option value="DELETE">DELETE</option>
            </select>
            <input class="input" [(ngModel)]="form.maxRetries" type="number" min="0" max="10" placeholder="Max retries (0-10)" style="width:140px">
          </div>
          <label class="field-label">Headers (JSON, optional)</label>
          <textarea class="input" [(ngModel)]="form.headersStr" rows="2" placeholder='{"Authorization":"Bearer ..."}' style="resize:vertical;width:100%;box-sizing:border-box;font-family:monospace;font-size:11px"></textarea>
          <label class="field-label">Body Template <span style="font-size:10px;font-weight:400;color:var(--muted)">Supports [event], [tunnelId], etc.</span></label>
          <textarea class="input" [(ngModel)]="form.bodyTemplate" rows="3" placeholder="Custom JSON body (leave empty for default)" style="resize:vertical;width:100%;box-sizing:border-box;font-family:monospace;font-size:11px"></textarea>
        } @else if (form.type==='slack'||form.type==='discord') {
          <input class="input" [(ngModel)]="form.webhookUrl" [placeholder]="form.type==='slack'?'Slack Webhook URL':'Discord Webhook URL'" style="width:100%;margin-top:12px">
          <div class="bind-row" style="margin-top:12px">
            <input class="input" [(ngModel)]="form.maxRetries" type="number" min="0" max="10" placeholder="Max retries (0-10)" style="width:140px">
          </div>
        } @else if (form.type==='telegram') {
          <input class="input" [(ngModel)]="form.botToken" placeholder="Bot Token" style="width:100%;margin-top:12px">
          <input class="input" [(ngModel)]="form.channelId" placeholder="Chat ID" style="width:100%;margin-top:12px">
          <div class="bind-row" style="margin-top:12px">
            <input class="input" [(ngModel)]="form.maxRetries" type="number" min="0" max="10" placeholder="Max retries (0-10)" style="width:140px">
          </div>
        }

        <label class="field-label" style="margin-top:12px">Triggers</label>
        <div class="toggle-all" style="margin-bottom:8px">
          <label class="switch"><input type="checkbox" [checked]="allTriggersSelected()" (change)="toggleAllTriggers()"><span></span></label>
          <span style="font-size:12px;margin-left:4px;color:var(--muted)">All events</span>
        </div>
        <div class="tag-row">
          @for (t of ALL_TRIGGERS; track t.key) {
            <span class="tag-chip preset" [class.selected]="form.triggers.includes(t.key)" [style.background]="form.triggers.includes(t.key)?'var(--accent)':'transparent'" [style.color]="form.triggers.includes(t.key)?'#fff':'var(--muted)'" [style.border-color]="form.triggers.includes(t.key)?'var(--accent)':'var(--border)'" (click)="toggleTrigger(t.key)">{{t.label}}</span>
          }
        </div>

        <div class="bind-row" style="margin-top:16px;justify-content:flex-end">
          <button class="btn btn-ghost btn-sm" (click)="closeForm()">Cancel</button>
          @if (editId) { <button class="btn btn-ghost btn-sm" (click)="testWebhook(editId)">Test</button> }
          <button class="btn btn-primary btn-sm" (click)="saveWebhook()">{{editId?'Update':'Create'}}</button>
        </div>
      </div></div>
    }

    @if (hooks().length === 0) { <div class="empty">No webhooks configured</div> }
    @for (w of hooks(); track w.id) {
      <div class="card hook-row">
        <div class="hook-info">
          <b>{{w.name}}</b>
          <span class="badge" [ngClass]="w.enabled!==false?'badge-green':'badge-gray'">{{w.enabled!==false?'ACTIVE':'DISABLED'}}</span>
          <span class="badge badge-gray">{{w.type.toUpperCase()}}</span>
          @if (w.type==='http' && w.url) { <span class="muted text-xs" style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{w.url}}</span> }
          @if ((w.type==='slack'||w.type==='discord') && w.webhookUrl) { <span class="muted text-xs" style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{w.webhookUrl}}</span> }
          @if (w.type==='telegram') { <span class="muted text-xs">&#64;{{w.channelId||'?'}}</span> }
          <span class="muted text-xs">{{(w.triggers||[]).length}} trigger(s)</span>
          @if (w.maxRetries != null) { <span class="muted text-xs">{{w.maxRetries}} retries</span> }
        </div>
        <div class="action-cell">
          <button class="btn btn-ghost btn-xs" (click)="testWebhook(w.id)">Test</button>
          <button class="btn btn-ghost btn-xs" (click)="editWebhook(w)"><span class="material-icons" style="font-size:14px">edit</span></button>
          <button class="btn btn-ghost btn-xs" (click)="toggleEnabled(w)">{{w.enabled!==false?'Disable':'Enable'}}</button>
          <button class="btn btn-ghost btn-xs danger" (click)="delWebhook(w.id)"><span class="material-icons" style="font-size:14px">delete_outline</span></button>
        </div>
      </div>
    }
  `,
})
export class WebhooksComponent implements OnInit {
  private api = inject(ApiService);
  private toast = inject(ToastService);
  loading = signal(false);
  hooks = signal<WebhookConfig[]>([]);
  showForm = false; editId = '';
  form: any = this.emptyForm();
  ALL_TRIGGERS = ALL_TRIGGERS;

  ngOnInit() { this.loadWebhooks(); }

  emptyForm() { return { name:'', type:'http' as string, enabled:true, triggers:[] as string[], url:'', method:'POST', headersStr:'', bodyTemplate:'', webhookUrl:'', botToken:'', channelId:'', maxRetries:3 }; }

  openForm() { this.form = this.emptyForm(); this.editId = ''; this.showForm = true; }
  closeForm() { this.showForm = false; this.editId = ''; }

  onTypeChange() {
    this.form.url = ''; this.form.webhookUrl = ''; this.form.botToken = ''; this.form.channelId = '';
    if (this.form.type === 'http') this.form.method = 'POST';
  }

  allTriggersSelected() { return ALL_TRIGGERS.every(t => this.form.triggers.includes(t.key)); }
  toggleAllTriggers() {
    if (this.allTriggersSelected()) this.form.triggers = [];
    else this.form.triggers = ALL_TRIGGERS.map(t => t.key);
  }
  toggleTrigger(key: string) {
    const i = this.form.triggers.indexOf(key);
    if (i >= 0) this.form.triggers.splice(i, 1); else this.form.triggers.push(key);
    this.form.triggers = [...this.form.triggers];
  }

  async loadWebhooks() { this.loading.set(true); try { const r = await this.api.call('/api/webhooks'); this.hooks.set(r.webhooks||[]); } catch {} finally { this.loading.set(false); } }

  async saveWebhook() {
    if (!this.form.name) return this.toast.show('Name required', true);
    const body: any = { name: this.form.name, enabled: this.form.enabled, type: this.form.type, triggers: this.form.triggers, maxRetries: +(this.form.maxRetries||3) };
    if (this.form.type === 'http') { body.url = this.form.url; body.method = this.form.method||'POST'; body.bodyTemplate = this.form.bodyTemplate; if (this.form.headersStr) { try { body.headers = JSON.parse(this.form.headersStr); } catch { return this.toast.show('Invalid headers JSON', true); } } }
    else if (this.form.type === 'slack' || this.form.type === 'discord') { body.webhookUrl = this.form.webhookUrl; }
    else if (this.form.type === 'telegram') { body.botToken = this.form.botToken; body.channelId = this.form.channelId; }
    this.loading.set(true);
    try {
      if (this.editId) { body.id = this.editId; await this.api.call('/api/webhooks/'+this.editId,'PUT',body); this.toast.show('Updated'); }
      else { const r = await this.api.call('/api/webhooks','POST',body); this.toast.show('Created'); }
      this.closeForm();
      await this.loadWebhooks();
      await this.api.call('/api/webhooks/reload','POST').catch(()=>{});
    } catch(e:any) { this.toast.show((e.error||'Error'),true); this.loading.set(false); }
  }

  editWebhook(w: WebhookConfig) {
    this.editId = w.id;
    this.form = { name: w.name, type: w.type, enabled: w.enabled !== false, triggers: [...(w.triggers||[])], url: w.url||'', method: w.method||'POST', headersStr: w.headers?JSON.stringify(w.headers):'', bodyTemplate: w.bodyTemplate||'', webhookUrl: w.webhookUrl||'', botToken: w.botToken||'', channelId: w.channelId||'', maxRetries: w.maxRetries??3 };
    this.showForm = true;
  }

  async toggleEnabled(w: WebhookConfig) {
    this.loading.set(true);
    try {
      const body: any = { name: w.name, enabled: !(w.enabled !== false), type: w.type, triggers: w.triggers||[], maxRetries: w.maxRetries??3 };
      if (w.type === 'http') { body.url = w.url; body.method = w.method||'POST'; body.bodyTemplate = w.bodyTemplate; if (w.headers) body.headers = w.headers; }
      else if (w.type === 'slack' || w.type === 'discord') { body.webhookUrl = w.webhookUrl; }
      else if (w.type === 'telegram') { body.botToken = w.botToken; body.channelId = w.channelId; }
      await this.api.call('/api/webhooks/'+w.id,'PUT',body);
      await this.loadWebhooks();
      await this.api.call('/api/webhooks/reload','POST').catch(()=>{});
    } catch(e:any) { this.toast.show((e.error||'Error'),true); }
    this.loading.set(false);
  }

  async testWebhook(id:string) { this.loading.set(true); try { await this.api.call('/api/webhooks/'+id+'/test','POST'); this.toast.show('Test passed'); } catch { this.toast.show('Test failed',true); } finally { this.loading.set(false); } }
  async delWebhook(id:string) { if(!confirm('Delete?')) return; this.loading.set(true); try { await this.api.call('/api/webhooks/'+id,'DELETE'); await this.loadWebhooks(); await this.api.call('/api/webhooks/reload','POST').catch(()=>{}); this.toast.show('Deleted'); } catch { this.toast.show('Error',true); this.loading.set(false); } }
}
