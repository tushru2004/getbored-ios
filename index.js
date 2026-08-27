import {AppRegistry} from 'react-native';
import App from './App';
import {name as appName} from './app.json';

/**
 * React Native starts here after the iOS host loads the JavaScript bundle.
 *
 *   iOS loads main.jsbundle
 *       │
 *       ▼
 *   AppRegistry.registerComponent(appName, () => App)
 *       │
 *       ▼
 *   React Native creates <App> → <HomeScreen>
 */
AppRegistry.registerComponent(appName, () => App);
