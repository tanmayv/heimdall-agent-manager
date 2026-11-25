import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { heimdallApi } from '../../../src/ui/api/heimdallApi';
import vault from '../../../src/ui/store/vaultSlice';
import HomePage, { HomeDashboard } from '../../../src/ui/components/home/HomePage';
import { AuthUserProvider } from '../../../src/ui/components/auth/AuthUserContext';
import ActivityWidget from '../../../src/ui/components/home/ActivityWidget';
import TaskChainsWidget from '../../../src/ui/components/home/TaskChainsWidget';
import UptimeWidget from '../../../src/ui/components/home/UptimeWidget';
import FleetWidget from '../../../src/ui/components/home/FleetWidget';
import { mockActivity } from '../../../src/ui/components/home/homeWidgetFixtures';
import { summarizeActivity } from '../../../src/ui/components/home/widgetData';
import '../../../src/ui/styles.css';

const store = configureStore({ reducer: { vault, [heimdallApi.reducerPath]: heimdallApi.reducer }, middleware: (getDefault) => getDefault({ serializableCheck: false }).concat(heimdallApi.middleware) });
const params = new URLSearchParams(location.search);
const zero = mockActivity('tasks_completed');
zero.days.forEach((day) => { day.value = 0; });
zero.summary = summarizeActivity(zero.days, 'counter');
document.body.style.margin = '0';
document.body.style.background = 'var(--color-canvas)';
const style = document.createElement('style');
style.textContent = 'html{scrollbar-width:none}html,body,#root{height:auto;max-height:none;min-height:100vh;overflow:visible}body{position:static;inset:auto}.fixture-shell{display:grid;grid-template-columns:260px minmax(0,1fr);min-height:100vh}.fixture-sidebar{background:var(--color-surface);border-right:1px solid var(--color-border-subtle);padding:24px;color:var(--color-text-primary)}.fixture-main{padding:24px 16px}@media(max-width:767px){.fixture-shell{display:block}.fixture-sidebar{display:none}.fixture-main{padding:0}}';
document.head.append(style);
createRoot(document.getElementById('root')!).render(<Provider store={store}><div className="fixture-shell"><aside className="fixture-sidebar">Ninjy</aside><main className="fixture-main">
  <AuthUserProvider value={{ user_id: 'home-visual-fixture' }}>
    {params.has('empty') ? <HomeDashboard userId="home-visual-fixture" widgets={{
      activity: <ActivityWidget resource={{ status: 'ready', data: zero }} />,
      chains: <TaskChainsWidget resource={{ status: 'ready', data: [] }} />,
      uptime: <UptimeWidget resource={{ status: 'ready', data: { connected: 0, total: 0, uptimePercent: 0, bridges: [] } }} />,
      fleet: <FleetWidget resource={{ status: 'ready', data: [] }} />,
    }} /> : <HomePage />}
  </AuthUserProvider>
</main></div></Provider>);
