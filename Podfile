platform :ios, '13.0'

use_frameworks! :linkage => :static

project 'WudiApp.xcodeproj'

target 'WudiApp' do
  pod 'OUICore', :path => '../openim-ios'
  pod 'OUICoreView', :path => '../openim-ios'
  pod 'OUIIM', :path => '../openim-ios'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
