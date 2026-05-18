require_relative 'node_modules/react-native/scripts/react_native_pods'

platform :ios, '15.1'
prepare_react_native_project!

target 'GetBored iOS' do
  use_react_native!(
    :path => './node_modules/react-native',
    :hermes_enabled => true,
    :fabric_enabled => false,
    :app_path => "#{Pod::Config.instance.installation_root}"
  )
end

post_install do |installer|
  react_native_post_install(
    installer,
    './node_modules/react-native',
    :mac_catalyst_enabled => false
  )

  # Workaround: Xcode 26.4's Apple Clang rejects fmt's consteval format-string
  # checks. Downgrade only the fmt pod to C++17 so the consteval path is
  # skipped. Remove when RN vendors a newer fmt.
  # https://bleepingswift.com/blog/fmt-consteval-error-xcode-26-4-react-native
  installer.pods_project.targets.each do |target|
    if target.name == 'fmt'
      target.build_configurations.each do |config|
        config.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
      end
    end
  end
end
