import { configureStore } from '@reduxjs/toolkit';
import chatReducer from './chatSlice';
import taskReducer from './taskSlice';
import memoryReducer from './memorySlice';
import projectReducer from './projectSlice';
import homeReducer from './homeSlice';
import chainViewReducer from './chainViewSlice';

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
  },
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware().concat(actionLogger),
});
