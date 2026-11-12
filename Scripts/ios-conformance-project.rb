#!/usr/bin/env ruby
require 'xcodeproj'
require 'pathname'

root = Pathname.new(__dir__).parent.realpath
output = Pathname.new(ARGV.fetch(0, root.join('.build/conformance/iOSConformance.xcodeproj').to_s)).expand_path
project = Xcodeproj::Project.new(output)
host = project.new_target(:application, 'iOSConformanceHost', :ios, '17.0', nil, :swift)
host.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.ronnie.pi-ai-swift.conformance.host',
    'SWIFT_VERSION' => '6.0',
    'CODE_SIGN_IDENTITY' => '-',
    'CODE_SIGN_ENTITLEMENTS' => root.join('Tests/iOSConformance/ConformanceHost.entitlements').to_s,
    'TARGETED_DEVICE_FAMILY' => '1,2'
  )
end
host_source = project.main_group.new_file(root.join('Tests/iOSConformance/ConformanceHost.swift').to_s)
host.source_build_phase.add_file_reference(host_source)
target = project.new_target(:unit_test_bundle, 'iOSConformance', :ios, '17.0', nil, :swift)
target.add_dependency(host)
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.ronnie.pi-ai-swift.conformance',
    'SWIFT_VERSION' => '6.0',
    'CODE_SIGN_IDENTITY' => '-',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/iOSConformanceHost.app/iOSConformanceHost',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'TARGETED_DEVICE_FAMILY' => '1,2'
  )
end

source = project.main_group.new_file(root.join('Tests/iOSConformance/ProviderRuntimeConformanceTests.swift').to_s)
target.source_build_phase.add_file_reference(source)
body_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/FixtureHTTPBody.swift').to_s)
target.source_build_phase.add_file_reference(body_helper)
role_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/OpenAIInstructionRoleFixtures.swift').to_s)
target.source_build_phase.add_file_reference(role_helper)
installation_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/InstallationContextFixtures.swift').to_s)
target.source_build_phase.add_file_reference(installation_helper)
codex_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/CodexTransportFixtures.swift').to_s)
target.source_build_phase.add_file_reference(codex_helper)
cloud_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/CloudAuthorizationFixtures.swift').to_s)
target.source_build_phase.add_file_reference(cloud_helper)
adaptation_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/ProviderAdaptationFixtures.swift').to_s)
target.source_build_phase.add_file_reference(adaptation_helper)
primary_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/PrimaryAuthorizationFixtures.swift').to_s)
target.source_build_phase.add_file_reference(primary_helper)
oauth_resolution_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/OAuthResolutionFixtures.swift').to_s)
target.source_build_phase.add_file_reference(oauth_resolution_helper)
credential_store_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/CredentialStoreFixtures.swift').to_s)
target.source_build_phase.add_file_reference(credential_store_helper)
copilot_url_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/CopilotDeviceURLFixtures.swift').to_s)
target.source_build_phase.add_file_reference(copilot_url_helper)
oauth_metadata_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/OAuthMetadataFixtures.swift').to_s)
target.source_build_phase.add_file_reference(oauth_metadata_helper)
oauth_refresh_lifecycle_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/OAuthRefreshLifecycleFixtures.swift').to_s)
target.source_build_phase.add_file_reference(oauth_refresh_lifecycle_helper)
auth_resolution_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/AuthResolutionFixtures.swift').to_s)
target.source_build_phase.add_file_reference(auth_resolution_helper)
radius_catalog_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/RadiusCatalogFixtures.swift').to_s)
target.source_build_phase.add_file_reference(radius_catalog_helper)
reasoning_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/ReasoningSelectionFixtures.swift').to_s)
overflow_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/ContextOverflowFixtures.swift').to_s)
target.source_build_phase.add_file_reference(overflow_helper)
personalization_helper = project.main_group.new_file(root.join('Tests/PiAIProviderRuntimeTests/OpenRouterPersonalizationFixtures.swift').to_s)
target.source_build_phase.add_file_reference(personalization_helper)
target.source_build_phase.add_file_reference(reasoning_helper)
%w[OpenAIRequestBranches Differential AzureOpenAIConfiguration].each do |folder|
  reference = project.main_group.new_file(root.join('Fixtures', folder).to_s)
  reference.last_known_file_type = 'folder'
  target.resources_build_phase.add_file_reference(reference)
end

package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = root.to_s
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = 'PiAIProviderRuntime'
target.package_product_dependencies << product
framework = project.new(Xcodeproj::Project::Object::PBXBuildFile)
framework.product_ref = product
target.frameworks_build_phase.files << framework
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target, false)
scheme.add_test_target(target)
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(project.path, 'iOSConformance')
puts output
