import { configureStore } from '@reduxjs/toolkit';
import { heimdallApi, setupHeimdallApiListeners } from '../api/heimdallApi';
import '../api/endpoints/tasks';
import '../api/endpoints/chats';
import chatReducer from './chatSlice';
import taskReducer from './taskSlice';
import memoryReducer from './memorySlice';
import projectReducer from './projectSlice';
import homeReducer from './homeSlice';
import chainViewReducer from './chainViewSlice';
import attentionReducer from './attentionSlice';
import toastReducer from './toastSlice';

const actionLogger = (store: any) => (next: any) => (action: any) => {
  if (import.meta.env.DEV) {
    console.log('[Redux Action]', action.type, action.payload);
  }
  return next(action);
};

export const store = configureStore({
  reducer: {
    chat: chatReducer,
    tasks: taskReducer,
    memory: memoryReducer,
    projects: projectReducer,
    home: homeReducer,
    chainView: chainViewReducer,
    attention: attentionReducer,
    toasts: toastReducer,
    [heimdallApi.reducerPath]: heimdallApi.reducer,
  },
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware().concat(actionLogger, heimdallApi.middleware),
});

setupHeimdallApiListeners(store.dispatch);
