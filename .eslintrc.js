module.exports = {
  root: true,
  extends: '@react-native',
  overrides: [
    {
      files: ['Sources/iOS/SafariChildRegistrationExtension/Resources/*.js'],
      env: {
        browser: true,
      },
      globals: {
        browser: 'readonly',
        chrome: 'readonly',
      },
    },
  ],
  rules: {
    'react-native/no-inline-styles': 'off',
  },
};
