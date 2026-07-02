import { ApplicationConfig } from '@angular/core';
import { provideRouter, Routes } from '@angular/router';

export const routes: Routes = [
  { path: '', redirectTo: 'dashboard', pathMatch: 'full' },
  { path: 'dashboard', loadComponent: () => import('./dashboard/dashboard.component').then(m => m.DashboardComponent) },
  { path: 'dns', loadComponent: () => import('./dns/dns.component').then(m => m.DnsComponent) },
  { path: 'webhooks', loadComponent: () => import('./webhooks/webhooks.component').then(m => m.WebhooksComponent) },
  { path: 'alerts', loadComponent: () => import('./alerts/alerts.component').then(m => m.AlertsComponent) },
  { path: 'backup', loadComponent: () => import('./backup/backup.component').then(m => m.BackupComponent) },
  { path: 'settings', loadComponent: () => import('./settings/settings.component').then(m => m.SettingsComponent) },
];

export const appConfig: ApplicationConfig = {
  providers: [
    provideRouter(routes),
  ]
};
