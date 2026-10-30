#!/usr/bin/env ruby
require 'xcodeproj'
require 'pathname'

root = Pathname.new(__dir__).parent.realpath
output = Pathname.new(ARGV.fetch(0, root.join('.build/conformance/iOSConformance.xcodeproj').to_s)).expand_path
project = Xcodeproj::Project.new(output)
target = project.new_target(:unit_test_bundle, 'iOSConformance', :ios, '17.0', nil, :swift)
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.ronnie.pi-ai-swift.conformance',
    'SWIFT_VERSION' => '6.0',
    'CODE_SIGN_IDENTITY' => '-',
    'TARGETED_DEVICE_FAMILY' => '1,2'
  )
end

source = project.main_group.new_file(root.join('Tests/iOSConformance/ProviderRuntimeConformanceTests.swift').to_s)
target.source_build_phase.add_file_reference(source)
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
