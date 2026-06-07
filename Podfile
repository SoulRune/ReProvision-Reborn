target 'iOS' do
platform :ios, '9.0'
pod 'OpenSSL-Universal', '1.0.2.13'
pod 'MBCircularProgressBar', '0.3.5'
pod 'MarqueeLabel', '3.1.4'
pod 'TORoundedTableView', '0.1.3'
pod 'RMessage', '2.1.5'
pod 'CocoaLumberjack'
end

target 'macOS' do
platform :osx, '10.10'
pod 'OpenSSL-Universal', '1.0.2.13'
end

target 'tvOS' do
platform :tvos, '9.0'
pod 'MarqueeLabel', '3.1.4'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      # Xcode 16: -Werror,-Wstrict-prototypes breaks old Firebase/Google pods.
      config.build_settings['GCC_TREAT_WARNINGS_AS_ERRORS'] = 'NO'
      config.build_settings['CLANG_WARN_STRICT_PROTOTYPES'] = 'NO'
      existing = config.build_settings['WARNING_CFLAGS'] || '$(inherited)'
      config.build_settings['WARNING_CFLAGS'] = "#{existing} -Wno-strict-prototypes -Wno-error=strict-prototypes -Wno-error"
      # Some pods set their deployment target below what Xcode 16 supports.
      if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_s.to_f < 12.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
      end
    end
  end
end
