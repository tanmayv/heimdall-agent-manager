import { configureStore } from '@reduxjs/toolkit';
import chatReducer from './chatSlice';
import taskReducer from './taskSlice';
import memoryReducer from './memorySlice';
import projectReducer from './projectSlice';

export const store = configureStore({
  reducer: {
    chat: chatReducer,
    tasks: taskReducer,
    memory: memoryReducer,
    projects: projectReducer,
  },
});
