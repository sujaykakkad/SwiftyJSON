//
//  Schema.swift
//  SwiftyJSON
//
//  Created by Sujay Kakkad on 15/05/17.
//
//

import Foundation

public enum Type1: String {
    case Object = "object"
    case Array = "array"
    case String = "string"
    case Integer = "integer"
    case Number = "number"
    case Boolean = "boolean"
    case Null = "null"
}

extension String {
    func stringByRemovingPrefix(_ prefix:String) -> String? {
        if hasPrefix(prefix) {
            let index = characters.index(startIndex, offsetBy: prefix.characters.count)
            return substring(from: index)
        }
        
        return nil
    }
}

public struct Schema {
    public let title:String?
    public let description:String?
    
    public let type:[Type1]?
    
    let formats: [String:Validator]
    let schema: JSON
    
    public init(_ schema: JSON) {
        title = schema["title"].string
        description = schema["description"].string
        
        if let type = schema["type"].string {
            if let type = Type1(rawValue: type) {
                self.type = [type]
            } else {
                self.type = []
            }
        } else if let types = schema["type"].array {
            self.type = types.map { Type1(rawValue: $0.stringValue) }.filter { $0 != nil }.map { $0! }
        } else {
            self.type = []
        }
        
        self.schema = schema
        
        formats = [
            "ipv4": validateIPv4,
            "ipv6": validateIPv6,
        ]
    }
    
    public func validate(_ data:Any) -> ValidationResult {
        let validator = allOf(validators(self)(schema))
        let result = validator(data)
        return result
    }
    
    func validatorForReference(_ reference:String) -> Validator {
        if let reference = reference.stringByRemovingPrefix("#") {
            if let tmp = reference.stringByRemovingPrefix("/"), let reference = (tmp as NSString).removingPercentEncoding {
                var components = reference.components(separatedBy: "/")
                var schema = self.schema
                while let component = components.first {
                    components.remove(at: components.startIndex)
                    
                    if schema[component].dictionary != nil {
                        continue
                    } else if let schemas = schema[component].array {
                        if let component = components.first, let index = Int(component) {
                            components.remove(at: components.startIndex)
                            
                            if schemas.count > index {
                                schema = schemas[index]
                                continue
                            }
                        }
                    }
                    
                    return invalidValidation("Reference not found '\(component)' in '\(reference)'")
                }
                
                return allOf(validators(self)(schema))
            } else if reference == "" {
                return { value in
                    return allOf(validators(self)(self.schema))(value)
                }
            }
        }
        
        return invalidValidation("Remote $ref '\(reference)' is not yet supported")
    }
}

func validators(_ root: Schema) -> (_ schema: JSON) -> [Validator] {
    return { schema in
        var validators = [Validator]()
        
        if let ref = schema["$ref"].string {
            validators.append(root.validatorForReference(ref))
        }
        
        if let type = schema["type"].array {
            validators.append(validateType(type.map({ $0.stringValue })))
        }
        if let type = schema["type"].string {
            validators.append(validateType(type))
        }
        
        
        if let allOf = schema["allOf"].array {
            validators += allOf.map(SwiftyJSON.validators(root)).reduce([], +)
        }
        
        if let anyOfSchemas = schema["anyOf"].array {
            let anyOfValidators = anyOfSchemas.map(SwiftyJSON.validators(root)).map(allOf) as [Validator]
            validators.append(anyOf(anyOfValidators))
        }
        
        if let oneOfSchemas = schema["oneOf"].array {
            let oneOfValidators = oneOfSchemas.map(SwiftyJSON.validators(root)).map(allOf) as [Validator]
            validators.append(oneOf(oneOfValidators))
        }
        
        if let notSchema = schema["not"].dictionaryObject {
            let notValidator = allOf(SwiftyJSON.validators(root)(JSON(notSchema)))
            validators.append(not(notValidator))
        }
        
        if let enumValues = schema["enum"].arrayObject {
            validators.append(validateEnum(enumValues))
        }
        
        if let maxLength = schema["maxLength"].int {
            validators.append(validateLength(<=, length: maxLength, error: "Length of string is larger than max length \(maxLength)"))
        }
        
        if let minLength = schema["minLength"].int {
            validators.append(validateLength(>=, length: minLength, error: "Length of string is smaller than minimum length \(minLength)"))
        }
        
        if let pattern = schema["pattern"].string {
            validators.append(validatePattern(pattern))
        }
        
        if let multipleOf = schema["multipleOf"].double {
            validators.append(validateMultipleOf(multipleOf))
        }
        
        if let minimum = schema["minimum"].double {
            validators.append(validateNumericLength(minimum, comparitor: >=, exclusiveComparitor: >, exclusive: schema["exclusiveMinimum"].bool, error: "Value is lower than minimum value of \(minimum)"))
        }
        
        if let maximum = schema["maximum"].double {
            validators.append(validateNumericLength(maximum, comparitor: <=, exclusiveComparitor: <, exclusive: schema["exclusiveMaximum"].bool, error: "Value exceeds maximum value of \(maximum)"))
        }
        
        if let minItems = schema["minItems"].int {
            validators.append(validateArrayLength(minItems, comparitor: >=, error: "Length of array is smaller than the minimum \(minItems)"))
        }
        
        if let maxItems = schema["maxItems"].int {
            validators.append(validateArrayLength(maxItems, comparitor: <=, error: "Length of array is greater than maximum \(maxItems)"))
        }
        
        if let uniqueItems = schema["uniqueItems"].bool {
            if uniqueItems {
                validators.append(validateUniqueItems)
            }
        }
        
        if let items = schema["items"].dictionaryObject {
            let itemsValidators = allOf(SwiftyJSON.validators(root)(JSON(items)))
            
            func validateItems(_ document:Any) -> ValidationResult {
                if let document = document as? [Any] {
                    return flatten(document.map(itemsValidators))
                }
                
                return .Valid
            }
            
            validators.append(validateItems)
        } else if let items = schema["items"].array {
            func createAdditionalItemsValidator(_ additionalItems:Any?) -> Validator {
                if let additionalItems = additionalItems as? [String:Any] {
                    return allOf(SwiftyJSON.validators(root)(JSON(additionalItems)))
                }
                
                let additionalItems = additionalItems as? Bool ?? true
                if additionalItems {
                    return validValidation
                }
                
                return invalidValidation("Additional results are not permitted in this array.")
            }
            
            let additionalItemsValidator = createAdditionalItemsValidator(schema["additionalItems"])
            let itemValidators = items.map(SwiftyJSON.validators(root))
            
            func validateItems(_ value:Any) -> ValidationResult {
                if let value = value as? [Any] {
                    var results = [ValidationResult]()
                    
                    for (index, element) in value.enumerated() {
                        if index >= itemValidators.count {
                            results.append(additionalItemsValidator(element))
                        } else {
                            let validators = allOf(itemValidators[index])
                            results.append(validators(element))
                        }
                    }
                    
                    return flatten(results)
                }
                
                return .Valid
            }
            
            validators.append(validateItems)
        }
        
        if let maxProperties = schema["maxProperties"].int {
            validators.append(validatePropertiesLength(maxProperties, comparitor: >=, error: "Amount of properties is greater than maximum permitted"))
        }
        
        if let minProperties = schema["minProperties"].int {
            validators.append(validatePropertiesLength(minProperties, comparitor: <=, error: "Amount of properties is less than the required amount"))
        }
        
        if let required = schema["required"].array {
            validators.append(validateRequired(required.map({ $0.stringValue })))
        }
        
        if (schema["properties"].dictionaryObject != nil) || (schema["patternProperties"].dictionaryObject != nil) || (schema["additionalProperties"].dictionaryObject != nil) {
            func createAdditionalPropertiesValidator(_ additionalProperties:Any?) -> Validator {
                if let additionalProperties = additionalProperties as? [String:Any] {
                    return allOf(SwiftyJSON.validators(root)(JSON(additionalProperties)))
                }
                
                let additionalProperties = additionalProperties as? Bool ?? true
                if additionalProperties {
                    return validValidation
                }
                
                return invalidValidation("Additional properties are not permitted in this object.")
            }
            
            func createPropertiesValidators(_ properties:[String: Any]?) -> [String:Validator]? {
                if let properties = properties {
                    return Dictionary(properties.keys.map {
                        key in (key, allOf(SwiftyJSON.validators(root)(JSON(properties[key]!))))
                    })
                }
                
                return nil
            }
            
            let additionalPropertyValidator = createAdditionalPropertiesValidator(schema["additionalProperties"])
            let properties = createPropertiesValidators(schema["properties"].dictionaryObject)
            let patternProperties = createPropertiesValidators(schema["patternProperties"].dictionaryObject)
            validators.append(validateProperties(properties, patternProperties: patternProperties, additionalProperties: additionalPropertyValidator))
        }
        
        func validateDependency(_ key: String, validator: @escaping Validator) -> (_ value: Any) -> ValidationResult {
            return { value in
                if let value = value as? [String:Any] {
                    if (value[key] != nil) {
                        return validator(value)
                    }
                }
                
                return .Valid
            }
        }
        
        func validateDependencies(_ key: String, dependencies: [String]) -> (_ value: Any) -> ValidationResult {
            return { value in
                if let value = value as? [String:Any] {
                    if (value[key] != nil) {
                        return flatten(dependencies.map { dependency in
                            if value[dependency] == nil {
                                return .invalid(["'\(key)' is missing it's dependency of '\(dependency)'"])
                            }
                            return .Valid
                        })
                    }
                }
                
                return .Valid
            }
        }
        
        if let dependencies = schema["dependencies"].dictionaryObject {
            for (key, dependencies) in dependencies {
                if let dependencies = dependencies as? [String: Any] {
                    let schema = allOf(SwiftyJSON.validators(root)(JSON(dependencies)))
                    validators.append(validateDependency(key, validator: schema))
                } else if let dependencies = dependencies as? [String] {
                    validators.append(validateDependencies(key, dependencies: dependencies))
                }
            }
        }
        
        if let format = schema["format"].string {
            if let validator = root.formats[format] {
                validators.append(validator)
            } else {
                validators.append(invalidValidation("'format' validation of '\(format)' is not yet supported."))
            }
        }
        
        return validators
    }
}

public func validate(_ value:Any, schema: JSON) -> ValidationResult {
    let root = Schema(schema)
    let validator = allOf(validators(root)(schema))
    let result = validator(value)
    return result
}

extension Dictionary {
    init(_ pairs: [Element]) {
        self.init()
        
        for (key, value) in pairs {
            self[key] = value
        }
    }
}
