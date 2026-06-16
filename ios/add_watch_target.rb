require 'xcodeproj'

proj_path = '/Users/admin/quadrille/ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(proj_path)

runner = project.targets.find { |t| t.name == 'Runner' }
abort 'no Runner target' unless runner

if project.targets.any? { |t| t.name == 'QuadrilleWatch' }
  puts 'QuadrilleWatch target already exists; nothing to do.'
  exit 0
end

release_xcconfig = project.files.find { |f| f.path == 'Flutter/Release.xcconfig' }
debug_xcconfig   = project.files.find { |f| f.path == 'Flutter/Debug.xcconfig' }
abort 'missing flutter xcconfigs' unless release_xcconfig && debug_xcconfig

# --- watchOS app target ---
watch = project.new_target(:application, 'QuadrilleWatch', :watchos, '9.0', nil, :swift)

watch.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER']         = 'app.quadrille.watch'
  bs['PRODUCT_NAME']                      = '$(TARGET_NAME)'
  bs['DEVELOPMENT_TEAM']                  = 'LHY8W725A8'
  bs['CODE_SIGN_STYLE']                   = 'Automatic'
  bs['INFOPLIST_FILE']                    = 'QuadrilleWatch/Info.plist'
  bs['GENERATE_INFOPLIST_FILE']           = 'NO'
  bs['WATCHOS_DEPLOYMENT_TARGET']         = '9.0'
  bs['TARGETED_DEVICE_FAMILY']            = '4'
  bs['SWIFT_VERSION']                     = '5.0'
  bs['SDKROOT']                           = 'watchos'
  bs['SUPPORTS_MACCATALYST']              = 'NO'
  bs['SKIP_INSTALL']                      = 'NO'
  bs['ASSETCATALOG_COMPILER_APPICON_NAME']= 'AppIcon'
  bs['CURRENT_PROJECT_VERSION']           = '$(FLUTTER_BUILD_NUMBER)'
  bs['MARKETING_VERSION']                 = '$(FLUTTER_BUILD_NAME)'
  bs['ENABLE_PREVIEWS']                   = 'YES'
  config.base_configuration_reference = (config.name == 'Debug' ? debug_xcconfig : release_xcconfig)
end

# --- source group + files ---
watch_group = project.main_group.find_subpath('QuadrilleWatch', true)
watch_group.set_path('QuadrilleWatch')

%w[QuadrilleWatchApp.swift WatchConnectivityManager.swift ActiveTimerView.swift].each do |fn|
  ref = watch_group.new_reference(fn)
  watch.add_file_references([ref])
end
assets_ref = watch_group.new_reference('Assets.xcassets')
watch.add_resources([assets_ref])
watch_group.new_reference('Info.plist')

# --- embed watch app into the iOS app ---
embed = runner.new_copy_files_build_phase('Embed Watch Content')
embed.dst_subfolder_spec = '16'                       # Products Directory
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
bf = embed.add_file_reference(watch.product_reference)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

runner.add_dependency(watch)

project.save
puts "OK: added QuadrilleWatch target (#{watch.uuid})"
puts "Runner build phases: #{runner.build_phases.map { |p| p.display_name }.join(', ')}"
puts "Watch sources: #{watch.source_build_phase.files.map { |f| f.display_name }.join(', ')}"
puts "Watch resources: #{watch.resources_build_phase.files.map { |f| f.display_name }.join(', ')}"
