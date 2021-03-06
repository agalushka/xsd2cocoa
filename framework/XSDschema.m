
//
//  XSDschema.m
//  xsd2cocoa
//
//  Created by Stefan Winter on 5/22/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//


#import "XSDschema.h"
#import "XSDschema+XPaths.h"

#import "XSSimpleType.h"
#import "XSDcomplexType.h"
#import "XSDelement.h"
#import "MGTemplateEngine.h"
#import "ICUTemplateMatcher.h"
#import "XMLUtils.h"
#import "DDXMLValidator.h"

#import "DDSimpleFormatter.h"

@interface XSDcomplexType (privateAccessors)
@property (strong, nonatomic) NSArray* globalElements;
@end

@interface XSDschema ()

@property (strong, nonatomic) NSString* schemaId;
@property (strong, nonatomic) NSURL* schemaUrl;
@property (strong, nonatomic) NSString* targetNamespace;
@property (strong, nonatomic) NSArray* allNamespaces;
@property (strong, nonatomic) NSArray* complexTypes;
@property (strong, nonatomic) NSArray* includedSchemas;
@property (strong, nonatomic) NSArray* simpleTypes;
@property (strong, nonatomic) NSString* xmlSchemaNamespace;

@property (weak, nonatomic) XSDschema* parentSchema;

@property (strong, nonatomic) NSString* complexTypeArrayType;
@property (strong, nonatomic) NSString* readComplexTypeElementTemplate;
@property (strong, nonatomic) NSString* readerClassTemplateString;
@property (strong, nonatomic) NSString* readerClassTemplateExtension;
@property (strong, nonatomic) NSString* readerHeaderTemplateString;
@property (strong, nonatomic) NSString* readerHeaderTemplateExtension;
@property (strong, nonatomic) NSString* classTemplateString;
@property (strong, nonatomic) NSString* classTemplateExtension;
@property (strong, nonatomic) NSString* headerTemplateString;
@property (strong, nonatomic) NSString* headerTemplateExtension;
@property (strong, nonatomic) NSString* enumClassTemplateString;
@property (strong, nonatomic) NSString* enumClassTemplateExtension;
@property (strong, nonatomic) NSString* enumHeaderTemplateString;
@property (strong, nonatomic) NSString* enumHeaderTemplateExtension;

@property (strong, nonatomic) NSXMLNode* enumReadNode;

@property (strong, nonatomic) NSDictionary* additionalFiles;
@property (strong, nonatomic) NSString *targetNamespacePrefix;
@property (strong, nonatomic) DDSimpleFormatter* formatter;

@end

@implementation XSDschema {
    NSMutableDictionary* _knownSimpleTypeDict;
    NSMutableDictionary* _knownComplexTypeDict;
}

// Called when initializing the object from a node
- (id) initWithNode:(NSXMLElement*)node targetNamespacePrefix:(NSString*)prefix error:(NSError**)error  {
	self = [super initWithNode:node schema:nil];
    if(self) {
        _knownSimpleTypeDict = [NSMutableDictionary dictionary];
        self.simpleTypes = [NSMutableArray array];
        _knownComplexTypeDict = [NSMutableDictionary dictionary];
        self.complexTypes = [NSMutableArray array];
        
        self.schemaId = [[node attributeForName: @"id"] stringValue];
        
        /* Get namespaces and set derived class prefix */
        self.targetNamespace = [[node attributeForName: @"targetNamespace"] stringValue];
        self.allNamespaces = [node namespaces];
        [self setTargetNamespacePrefixOverride:prefix];
        
       //find namespace for xs
        for(NSXMLNode *node in self.allNamespaces) {
            NSString *name = node.localName;
            id namespace = node.stringValue;
            if([namespace isEqualToString:@"http://www.w3.org/2001/XMLSchema"]) {
                if(name.length) NSLog(@"use namespace: %@=%@", name, namespace);
                self.xmlSchemaNamespace = name;
            }
        }
        if(!self.xmlSchemaNamespace) {
            for(NSXMLNode *node in self.allNamespaces) {
                NSString *name = node.localName;
                id namespace = node.stringValue;
                if([namespace hasPrefix:@"http://www.w3.org/"] && [namespace rangeOfString:@"XMLSchema"].location != NSNotFound) {
                    if(name.length) NSLog(@"use namespace: %@=%@", name, namespace);
                    self.xmlSchemaNamespace = name;
                }
            }
        }
        if(!self.xmlSchemaNamespace) {
            NSLog(@"Assume XMLNamespace is root");
            self.xmlSchemaNamespace = @"";
        }
        
        //handle includes & imports
        NSArray* iNodes = [node nodesForXPath: self.XPathForSchemaIncludes error: error];
        NSArray* iNodes2 = [node nodesForXPath: self.XPathForSchemaImports error: error];
        if(iNodes2.count) {
            NSMutableArray *newNodes = [iNodes2 mutableCopy];
            if(iNodes.count) {
                [newNodes addObjectsFromArray:iNodes];
            }
            iNodes = newNodes;
        }
        
        /* For the imported schemas, grab their complex and simple types of their elements */
        self.includedSchemas = [NSMutableArray array];
        for (NSXMLElement* aChild in iNodes) {
            
            id schemaLocation = [aChild attributeForName:@"schemaLocation"].stringValue;
            NSURL *url = [NSURL URLWithString:schemaLocation relativeToURL:self.schemaUrl];
            if(![[NSFileManager defaultManager] isReadableFileAtPath:url.path]) {
                if(error) {
                    *error = [NSError errorWithDomain:@"XSDschema" code:50 userInfo:@{@"url":url, NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"Cant open included xsd file at %@.", url]}];
                    
                }
                return nil;
            }
            XSDschema *xsd = [[self.class alloc] initWithUrl:url targetNamespacePrefix:prefix error:error];
            if(!xsd) {
                return nil;
            }
            
            xsd.parentSchema = self;
            [((NSMutableArray*)self.includedSchemas) addObject: xsd];
            
            //also add their types to ours, because we fricking know them now :D
            for (XSDcomplexType *ct in xsd.complexTypes) {
                [(NSMutableDictionary*)_knownComplexTypeDict setObject:ct forKey:ct.name];
                [(NSMutableArray*)self.complexTypes addObject:ct];
            }
            //also add their types to ours, because we fricking know them now :D
            for (XSSimpleType *ct in xsd.simpleTypes) {
                [(NSMutableDictionary*)_knownSimpleTypeDict setObject:ct forKey:ct.name];
                [(NSMutableArray*)self.simpleTypes addObject:ct];
            }
        }
        
        /* Add basic simple types known in the built-in types */
        for(XSSimpleType *aSimpleType in [XSSimpleType knownSimpleTypesForSchema:self]) {
            [_knownSimpleTypeDict setValue: aSimpleType forKey: aSimpleType.name];
            [((NSMutableArray*)self.simpleTypes) addObject:aSimpleType];
        }
        
        /* Add custom simple types */
        /* Grab all elements that are in the schema base with the simpleType element tag */
        NSArray* stNodes = [node nodesForXPath: self.XPathForSchemaSimpleTypes error: error];

        /* Iterate through the found elements */
        for (NSXMLElement* aChild in stNodes) {
            XSSimpleType* aST = [[XSSimpleType alloc] initWithNode:aChild schema:self];
            [((NSMutableDictionary*)_knownSimpleTypeDict) setObject:aST forKey:aST.name];
            [((NSMutableArray*)self.simpleTypes) addObject:aST];
        }

        /* Add complex types */
        NSArray* ctNodes = [node nodesForXPath: self.XPathForSchemaComplexTypes error: error];
        /* Iterate through the complex types found and create node elements for them */
        for (NSXMLElement* aChild in ctNodes) {
            XSDcomplexType* aCT = [[XSDcomplexType alloc] initWithNode:aChild schema:self];
            [((NSMutableDictionary*)_knownComplexTypeDict) setObject:aCT forKey:aCT.name];
            [((NSMutableArray*)self.complexTypes) addObject: aCT];
        }

        /* Add the globals elements */
        NSMutableArray* globalElements = [NSMutableArray array];
        NSArray* geNodes = [node nodesForXPath: self.XPathForSchemaGlobalElements error: error];
        for (NSXMLElement* aChild in geNodes) {
            XSDelement* anElement = [[XSDelement alloc] initWithNode: aChild schema: self];
            [globalElements addObject: anElement];
        }

        /* For each global element found, connect the type */
        for (XSDelement* anElement in globalElements) {
            id<XSType> aType = [anElement schemaType];
            /* For the type check if it is in our found complex types */
//            if( [aType isMemberOfClass: [XSDcomplexType class]]) {
                ((XSDcomplexType*)aType).globalElements = [((XSDcomplexType*)aType).globalElements arrayByAddingObject: anElement];
//            }
        }
	}
    
    /* Return our created object with all the elements and generated types */
	return self;
}

- (id) initWithUrl: (NSURL*) schemaUrl targetNamespacePrefix: (NSString*) prefix error: (NSError**) error {
    NSData* data = [NSData dataWithContentsOfURL: schemaUrl];
    /* If we do not have data present an instance error that we cannot open the xsd file at the given location */
    if(!data) {
        if(error) {
            *error = [NSError errorWithDomain:@"XSDschema" code:1 userInfo:@{NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"Cant open xsd file at %@", schemaUrl]}];
        }
        return nil;
    }
    /* Create a document tree structure */
    NSXMLDocument* doc = [[NSXMLDocument alloc] initWithData: data options: 0 error: error];
    if(!doc) {
        return nil;
    }
    
    /* The location of where our schema is located */
    self.schemaUrl = schemaUrl;
    
    /* From the root element, grab the complex, simple, and elements into their respective arrays */
    self = [self initWithNode: [doc rootElement] targetNamespacePrefix: prefix error: error];
    /* Continue to setup the schema */
    if (self) {
        
    }
    
    return self;
}

- (NSString*)nameSpacedSchemaNodeNameForNodeName:(NSString*)nodeName {
    NSParameterAssert(nodeName);
    
    if(self.xmlSchemaNamespace.length) {
        return [NSString stringWithFormat:@"%@:%@", self.xmlSchemaNamespace, nodeName];
    }
    else {
        return nodeName;
    }
}

#pragma mark -

- (void)setTargetNamespacePrefixOverride:(NSString*)prefix {
    //set class prefix
    if(prefix != nil) {
        self.targetNamespacePrefix = prefix;
    } else {
        for (NSXMLNode *node in self.allNamespaces) {
            NSString* nsURI = node.stringValue;
            
            if([nsURI isEqualTo: self.targetNamespace]) {
                self.targetNamespacePrefix = node.name;
            }
        }
    }
    
    //fix prefix so it is empty or uppercase
    if(!self.targetNamespacePrefix) {
        self.targetNamespacePrefix = @"";
    }
    else {
        if([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[self.targetNamespacePrefix characterAtIndex:0]]) {
            self.targetNamespacePrefix = self.targetNamespacePrefix;// uppercaseString];
        }
        else {
            self.targetNamespacePrefix = [self.targetNamespacePrefix uppercaseString];
        }
    }
}

- (void) addType: (XSDcomplexType*) cType {
    if([cType isKindOfClass:[XSDcomplexType class]]) {
        [((NSMutableDictionary*) _knownComplexTypeDict) setObject:cType forKey:cType.name];
        [((NSMutableArray*)self.complexTypes) addObject: cType];
    }
    else if([cType isKindOfClass:[XSSimpleType class]]) {
        [((NSMutableDictionary*) _knownSimpleTypeDict) setObject:cType forKey:cType.name];
        [((NSMutableArray*)self.simpleTypes) addObject: cType];
    }
}
/**
 * Name:        loadTemplate:(NSURL*)(NSError**)
 * Parameters:  (NSURL*) The specified template URL (location) as to where we are basing our simple types on and code to generate
 *              (NSError**) Associated error object pointer
 * Return:      BOOL - YES or NO if there was an error
 * Description: For each simple type that is defined in our template, fetch the associated elements
 *              that is within our XSD simpleTypes. Add the associated code that is defined within
 *              the template that will be used when we generate code for the complex types.
 *              Also define the header files
 */

- (BOOL) loadTemplate:(NSURL*)templateUrl error:(NSError**)resultError {
    NSParameterAssert(templateUrl);
    
    NSError *error = nil;
    
    /*validate it and fail if not valid*/
    NSURL *schemaUrl = [[NSBundle bundleForClass:self.class] URLForResource:@"template" withExtension:@"xsd"];
    BOOL valid = [[DDXMLValidator sharedInstace] validateXMLFile:templateUrl withSchema:DDXMLValidatorSchemaTypeXSD schemaFile:schemaUrl error:&error];
    if(!valid) {
        if(resultError) *resultError = error;
        return NO;
    }
    
    /* Load the template xml document */
    NSXMLDocument* xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL: templateUrl
                                                                 options:(NSXMLNodePreserveWhitespace|NSXMLNodePreserveCDATA)
                                                                   error: &error];
    /* Ensure that there wasn't errors */
    if(!xmlDoc  || error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }

    /* Check for additional file notes off of the template. */
    NSArray* additionalFileNodes = [xmlDoc nodesForXPath:self.XPathForTemplateAdditionalFiles error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    
    /* Fetch the additional filter defined in the additionfield fields above */
    NSMutableDictionary *mAdditionalFiles = [NSMutableDictionary dictionaryWithCapacity:additionalFileNodes.count];
    for(NSXMLElement* fileNode in additionalFileNodes) {
        NSString *path = [[[NSBundle bundleForClass:[XSDschema class]] resourcePath] stringByAppendingPathComponent:[fileNode attributeForName:@"path"].stringValue];
        if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            path = [fileNode attributeForName:@"path"].stringValue;
            if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                path = nil;
            }
        }
        
        if(path) {
            NSString *targetPath = [fileNode attributeForName:@"target_path"].stringValue;
            [mAdditionalFiles setObject:targetPath?targetPath:path forKey:path];
        }
    }
    /* If we have additonal files, add them to the schema */
    if(mAdditionalFiles.count) {
        self.additionalFiles = [NSDictionary dictionaryWithDictionary:mAdditionalFiles];
    }
    
    /* From the template, grab all the simple type elements and ensure that there wasn't an error */

    //
    //formatter style
    //
    NSArray* styleNodes = [xmlDoc nodesForXPath:self.XPathForTemplateFormatStyles error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    for(NSXMLElement* styleNode in styleNodes) {
        NSString *attr = [[styleNode attributeForName:@"type"] stringValue];
        if([attr isEqualToString:@"builtin"]) {
            self.formatter = [DDSimpleFormatter sharedInstance];
        }
        else {
            NSLog(@"Unknown formatter type: %@", attr);
        }
    }

    //
    // read templating code for enum type
    //
    
    //get the enumTypeNode
    NSArray *nodes = [xmlDoc nodesForXPath:self.XPathForTemplateFirstEnumeration error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    NSXMLElement *enumTypeNode = nil;
    if(nodes != nil && nodes.count > 0) {
        enumTypeNode = [nodes objectAtIndex: 0];
    }
    
    //reader
    nodes = [enumTypeNode nodesForXPath:self.XPathForTemplateReads error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.enumReadNode = [nodes objectAtIndex: 0];
    }
    
    /* Fetch the header file that we will use in the enumeration section */
    nodes = [enumTypeNode nodesForXPath:self.XPathForTemplateFirstImplementationHeaders error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.enumHeaderTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.enumHeaderTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    
    /* Fetch the class file that we will use in the enumeration section */
    nodes = [enumTypeNode nodesForXPath:self.XPathForTemplateFirstImplementationClasses error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.enumClassTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.enumClassTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
        
    //
    //reading simple types and merging them with our known ones
    //
    NSArray* simpleTypeNodes = [xmlDoc nodesForXPath:self.XPathForTemplateSimpleTypes error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    
    /* Iterate through the simple types found within the template */
    for(NSXMLElement* aSimpleTypeNode in simpleTypeNodes) {
        /* Build the node for the element found in the template */
        XSSimpleType* aSimpleType = [[XSSimpleType alloc] initWithNode:aSimpleTypeNode schema:self];
        
        /* For the name of the node found, check if we have that item created in our known types of the XSD*/
        XSSimpleType *existingSimpleType = _knownSimpleTypeDict[aSimpleType.name];
        
        /* Check if we have that simpletype within our XSD provided */
        if(existingSimpleType) {
            /* For our simple type, define the values from the template */
            [existingSimpleType supplyTemplates:aSimpleTypeNode enumTypeNode:self.enumReadNode error: &error];
        }
        else {
            [aSimpleType supplyTemplates:aSimpleTypeNode enumTypeNode:self.enumReadNode error:&error];
            [_knownSimpleTypeDict setValue: aSimpleType forKey: aSimpleType.name];
        }
    }
    
    //
    // read templating code for complex type
    //
    
    //get the complexTypeNode
    nodes = [xmlDoc nodesForXPath:self.XPathForTemplateFirstComplexType error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    NSXMLElement *complexTypeNode = nil;
    if(nodes != nil && nodes.count > 0) {
        complexTypeNode = [nodes objectAtIndex: 0];
    }

    /* Fetch the header file that we will use in the implementation section */
    nodes = [complexTypeNode nodesForXPath:self.XPathForTemplateFirstImplementationHeaders error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.headerTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.headerTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    
    /* Fetch the class file that we will use in the implementation section */
    nodes = [complexTypeNode nodesForXPath:self.XPathForTemplateFirstImplementationClasses error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.classTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.classTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    /* Fetch the code used to READ elements that have a complex type */
    nodes = [complexTypeNode nodesForXPath:self.XPathForTemplateFirstElementRead error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.readComplexTypeElementTemplate = [[nodes objectAtIndex: 0] stringValue];
    }
    
    //get the array type for complex types
    if(complexTypeNode) {
        self.complexTypeArrayType = [complexTypeNode attributeForName:@"arrayType"].stringValue;
    }
    
    /* Fetch the header file that we will use in the implementation section of the file reader */
    nodes = [complexTypeNode nodesForXPath:self.XPathForTemplateFirstReaderHeaders error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.readerHeaderTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.readerHeaderTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    /* Fetch the header file that we will use in the implementation section of the file reader */
    nodes = [complexTypeNode nodesForXPath:self.XPathForTemplateFirstReaderClasses error: &error];
    if(error != nil) {
        if(resultError) *resultError = error;
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.readerClassTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.readerClassTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    //
    //load included schemes
    //
    for (XSDschema *s in self.includedSchemas) {
        BOOL br = [s loadTemplate:templateUrl error:&error];
        if(!br) {
            return NO;
        }
    }
    return YES;
}

- (id<XSType>) typeForName: (NSString*) qName {
    if(self.parentSchema) {
        /* Defer */
        return [self.parentSchema typeForName:qName];
    }
    
    NSParameterAssert(qName.length); //EVERYTHING has a type name
    
    NSString* typeName = qName;
    NSArray* splitPrefix = [qName componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @":"]];
    
    if(splitPrefix.count > 1) {
        typeName = (NSString*) [splitPrefix objectAtIndex: 1];
    }
    
    /* Search the complexType dictionary for the type name */
    id<XSType> retType = [_knownComplexTypeDict objectForKey:typeName];
    
    /* Search the simpleType dictionary for the type name */
    if(!retType) {
        retType = [_knownSimpleTypeDict objectForKey:typeName];
    }
    
    assert(retType); //EVERYTHING has to have a type
    return retType;
}

- (NSString*)classPrefixForType:(id<XSType>)type {
    if(self.parentSchema) {
        //defer
        return [self.parentSchema classPrefixForType:type];
    }

    NSString *qName = [type name];

    NSParameterAssert(qName.length); //EVERYTHING has a type name
    
    NSArray* splitPrefix = [qName componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @":"]];
    
    NSString *namespace;
    if(splitPrefix.count > 1) {
        namespace = (NSString*) [splitPrefix objectAtIndex: 0];
    }
    
    if(!namespace || [namespace isEqualTo:self.targetNamespace]) {
        return self.targetNamespacePrefix;
    }
    else {
        return [self.targetNamespacePrefix stringByAppendingString:namespace.capitalizedString];
    }
}

+ (NSString*) variableNameFromName:(NSString*)vName multiple:(BOOL)multiple {
    NSParameterAssert(vName.length);
    
    NSCharacterSet* illegalChars = [NSCharacterSet characterSetWithCharactersInString: @"-"];
    NSRange range = [vName rangeOfCharacterFromSet: illegalChars];
    while(range.length > 0) {
        vName = [vName stringByReplacingCharactersInRange: range withString: @""];
        // range is now at next char
        vName = [vName stringByReplacingCharactersInRange: range withString:[[vName substringWithRange: range] uppercaseString]];
        
        range = [vName rangeOfCharacterFromSet: illegalChars];
    }
    
    //grammar fix
    if(multiple) {
        if(![vName hasSuffix:@"s"])
        {
            if([vName hasSuffix:@"y"]) {
                vName = [vName substringToIndex:vName.length-1];
                vName = [vName stringByAppendingString:@"ies"];
            }
            else {
                vName = [vName stringByAppendingString:@"s"];
            }
        }
    }
    
    //name fixes
    id newName = [[self.class knownNameChanges] objectForKey:vName];
    if(newName) {
        vName = newName;
    }
    
    assert(vName.length); //EVERYTHING has a name
    
    return vName;
}

#pragma mark

+ (NSDictionary *)knownNameChanges {
    static NSDictionary* knownNameChanges;
    if(!knownNameChanges) {
        NSURL *url = [[NSBundle bundleForClass:[self class]] URLForResource:@"nameChanges" withExtension:@"xml"];
        NSData* data = [NSData dataWithContentsOfURL: url];
        NSXMLDocument* doc = [[NSXMLDocument alloc] initWithData: data options: 0 error: nil];
        if(!doc) {
            return nil;
        }
        NSArray* iNodes = [[doc rootElement] nodesForXPath: [self XPathForNamechanges] error: nil];
        
        knownNameChanges  = [NSMutableDictionary dictionaryWithCapacity:iNodes.count];
        for (NSXMLElement *element in iNodes) {
            id from = [XMLUtils node:element stringAttribute:@"from"];
            id to = [XMLUtils node:element stringAttribute:@"to"];
            [(NSMutableDictionary*)knownNameChanges setObject:to forKey:from];             
        }
    }
    return knownNameChanges;
}

#pragma mark - generator
/**
 * Name:        generateInto (NSURL*)(XSDschemaGeneratorOptions)(NSError**)
 * Parameters:  (NSURL*)destinationFolder - the location where we will be writing the documents to
 *              (XSDschemaGeneratorOptions) - the options that the user selected and the type of code to write
 *              (NSError**) - error pointing object
 * Return:      BOOL - YES or NO if there was an error
 * Description: Will generate the code for the complex types that are used within the schema into objective-c
 *              by using the templates for the simple types (loadTemplates). This will render the template code
 *              and insert the proper values into the template space. Will return if there is an error
 */
- (BOOL) generateInto:(NSURL*)destinationFolder
             products:(XSDschemaGeneratorOptions)options
                error:(NSError**)error {
    NSParameterAssert(destinationFolder);
    NSParameterAssert(error);
    
    /* SOURCE CODE - If we want to write source code */
    if (options & (XSDschemaGeneratorOptionSourceCode | XSDschemaGeneratorOptionSourceCodeWithSubfolders)) {
        /* Create the path that will contain all the code */
        NSURL *srcFolderUrl = [destinationFolder URLByAppendingPathComponent:@"Sources" isDirectory:YES];
        
        /* Create the actual directory at the location defined above */
        if(![[NSFileManager defaultManager] createDirectoryAtURL:srcFolderUrl withIntermediateDirectories:YES attributes:nil error:error]) {
            BOOL isDir;
            /* Ensure that the item was created */
            if(![[NSFileManager defaultManager] fileExistsAtPath:srcFolderUrl.path isDirectory:&isDir] || !isDir) {
                return NO;
            }
        }
        /* If all is well, start writing the code into the directory we created */
        if(![self writeCodeInto:srcFolderUrl createSubfolders:options & XSDschemaGeneratorOptionSourceCodeWithSubfolders error:error]) {
            return NO;
        }
        if(![self formatFilesInFolder:srcFolderUrl error:nil])  {
            return NO;
        }
    }

    return YES;
}

/**
 * Name:        writeCodeInto (NSURL*)(NSError**)
 * Parameters:  (NSURL*)destinationFolder - the location where we will be writing the documents to
 *              (NSError**) - error pointing object
 * Return:      BOOL - YES or NO if there was an error
 * Description: Will consume the complex types
 *
 */
- (BOOL) writeCodeInto: (NSURL*) destinationFolder
      createSubfolders: (BOOL) createSubfolders
                 error: (NSError**) error {
    /* If there is no template, return that is failed */
    if(!self.complexTypeArrayType) {
        return NO;
    }

    //copy additional files
    [self.additionalFiles enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *srcPath = key;
        NSString *destPath = [destinationFolder.path stringByAppendingPathComponent:obj];
        [[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:destPath error:nil];
    }];

    // Set up template engine with your chosen matcher.
    MGTemplateEngine *engine = [MGTemplateEngine templateEngine];
    [engine setMatcher:[ICUTemplateMatcher matcherWithTemplateEngine:engine]];
    
    /* Start writing our classes for the complex types */
    for(XSDcomplexType* type in self.complexTypes) {
        /* Create the items for the header file */
        if (self.headerTemplateString.length) {
            /* Generate the code from the template and from the variables */
            NSString *result = [engine processTemplate:self.headerTemplateString
                                         withVariables:type.substitutionDict];
            
            NSString* headerFileName = [NSString stringWithFormat: @"%@.%@", type.targetClassFileName, self.headerTemplateExtension];
            NSURL* headerFilePath = [createSubfolders ? [self subfolderForURL:destinationFolder schema:type.schema] : destinationFolder URLByAppendingPathComponent: headerFileName];
            BOOL br = [result writeToURL: headerFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];

            /* Ensure that there was no errors for writing */
            if(!br) {
                return NO;
            }
        }
        
        /* Create the items for the class file */
        if (self.classTemplateString.length) {
            /* Generate the code from the template and the variables */
            NSString *result = [engine processTemplate: self.classTemplateString
                                         withVariables: type.substitutionDict];
            
            NSString* classFileName = [NSString stringWithFormat: @"%@.%@", type.targetClassFileName, self.classTemplateExtension];
            NSURL* classFilePath = [createSubfolders ? [self subfolderForURL:destinationFolder schema:type.schema] : destinationFolder URLByAppendingPathComponent: classFileName];
            BOOL br = [result writeToURL:classFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];
            
            /* Ensure that there was no errors for writing */
            if(!br) {
                return NO;
            }
        }
        
        /* Create the files for the global elements */
        if(type.globalElements.count) {
            if (self.readerHeaderTemplateString.length) {
                NSString *result = [engine processTemplate: self.readerHeaderTemplateString
                                             withVariables: type.substitutionDict];
                
                NSString* headerFileName = [NSString stringWithFormat: @"%@+File.%@", type.targetClassFileName, self.readerHeaderTemplateExtension];
                NSURL* headerFilePath = [createSubfolders ? [self subfolderForURL:destinationFolder schema:type.schema] : destinationFolder URLByAppendingPathComponent: headerFileName];
                BOOL br = [result writeToURL: headerFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];

                /* Ensure that there was no errors for writing */
                if(!br) {
                    return NO;
                }
            }
            
            if (self.readerClassTemplateString.length) {
                NSString *result = [engine processTemplate: self.readerClassTemplateString
                                             withVariables: type.substitutionDict];
                
                NSString* classFileName = [NSString stringWithFormat: @"%@+File.%@", type.targetClassFileName, self.readerClassTemplateExtension];
                NSURL* classFilePath = [createSubfolders ? [self subfolderForURL:destinationFolder schema:type.schema] : destinationFolder URLByAppendingPathComponent: classFileName];
                BOOL br = [result writeToURL: classFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];
                
                /* Ensure that there was no errors for writing */
                if(!br) {
                    return NO;
                }
            }
        }
    }
    
    
    /* Start writing our classes for the simpletypes WHICH do have an enumeration */
    for(XSSimpleType* type in self.simpleTypes) {
        //we skip types that arent enums
        if(!type.hasEnumeration) {
            continue;
        }
        
        /* Create the items for the enum header file */
        if (self.enumHeaderTemplateString.length) {
            /* Generate the code from the template and from the variables */
            NSString *result = [engine processTemplate:self.enumHeaderTemplateString
                                         withVariables:type.substitutionDict];
            
            NSString* headerFileName = [NSString stringWithFormat: @"%@.%@", type.enumerationFileName, self.enumHeaderTemplateExtension];
            NSURL* headerFilePath = [createSubfolders ? [self subfolderForURL:destinationFolder schema:type.schema] : destinationFolder URLByAppendingPathComponent: headerFileName];
            BOOL br = [result writeToURL: headerFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];
            
            /* Ensure that there was no errors for writing */
            if(!br) {
                return NO;
            }
        }
        
        /* Create the items for the enum class file */
        if (self.enumClassTemplateString.length) {
            /* Generate the code from the template and the variables */
            NSString *result = [engine processTemplate: self.enumClassTemplateString
                                         withVariables: type.substitutionDict];
            
            NSString* classFileName = [NSString stringWithFormat: @"%@.%@", type.enumerationFileName, self.enumClassTemplateExtension];
            NSURL* classFilePath = [createSubfolders ? [self subfolderForURL:destinationFolder schema:type.schema] : destinationFolder URLByAppendingPathComponent: classFileName];
            BOOL br = [result writeToURL:classFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];
            
            /* Ensure that there was no errors for writing */
            if(!br) {
                return NO;
            }
        }
    }
    
    //umbrella header - objC hack
    if([self.headerTemplateExtension isEqualToString:@"h"]) {
        //add header
        NSString *fileName = [NSString stringWithFormat:@"%@.h", self.schemaUrl.lastPathComponent.stringByDeletingPathExtension];
        NSURL *filePath = [destinationFolder URLByAppendingPathComponent:fileName];
        if([[NSFileManager defaultManager] fileExistsAtPath:filePath.path]) {
            fileName = [NSString stringWithFormat:@"%@Headers.h", self.schemaUrl.lastPathComponent.stringByDeletingPathExtension];
            filePath = [destinationFolder URLByAppendingPathComponent:fileName];
        }
        
        //add includes for all other files
        NSString *includes = [self contentOfObjcUmbrellaHeaderForFolder:destinationFolder];
        BOOL br = [includes writeToURL:filePath atomically:YES encoding:NSUTF8StringEncoding error:error];
        if(!br) {
            return NO;
        }
    }
    
    return YES;
}

- (NSURL *)subfolderForURL:(NSURL *)url schema:(XSDschema *)schema {
    NSURL *destinationSubfolder = [url copy];
    if (schema.schemaId) {
        destinationSubfolder = [destinationSubfolder URLByAppendingPathComponent:schema.schemaId isDirectory:YES];
    }
    else {
        destinationSubfolder = [destinationSubfolder URLByAppendingPathComponent:schema.schemaUrl.lastPathComponent.stringByDeletingPathExtension isDirectory:YES];
    }
    if(![[NSFileManager defaultManager] createDirectoryAtURL:destinationSubfolder withIntermediateDirectories:YES attributes:nil error:nil]) {
        BOOL isDir;
        /* Ensure that the item was created */
        if(![[NSFileManager defaultManager] fileExistsAtPath:destinationSubfolder.path isDirectory:&isDir] || !isDir) {
            return NO;
        }
    }
    return destinationSubfolder;
}

- (NSString*)contentOfObjcUmbrellaHeaderForFolder:(NSURL*)destinationFolder {
    NSParameterAssert(destinationFolder);
    
    NSDirectoryEnumerator *dirEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:destinationFolder
                                                                includingPropertiesForKeys:@[ NSURLNameKey, NSURLIsDirectoryKey ]
                                                                                   options:NSDirectoryEnumerationSkipsPackageDescendants| NSDirectoryEnumerationSkipsHiddenFiles
                                                                              errorHandler:nil];

    NSMutableString *includes = [NSMutableString string];
    for (NSURL *theURL in dirEnumerator) {
        NSNumber *isDirectory;
        [theURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (![isDirectory boolValue]) {
            if([theURL.pathExtension isEqualTo:@"h"]) {
                if(includes.length) {
                    [includes appendString:@"\n"];
                }
                [includes appendFormat:@"#import \"%@\"", theURL.lastPathComponent];
            }
        }
    }
    
    return includes;
}

- (BOOL) formatFilesInFolder: (NSURL*) destinationFolder
                       error: (NSError**) error {
    //CAN BE SKIPPED
    if(!self.formatter) return YES;
    
    NSParameterAssert(destinationFolder);
    
    NSDirectoryEnumerator *dirEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:destinationFolder
                                                                includingPropertiesForKeys:@[ NSURLNameKey, NSURLIsDirectoryKey ]
                                                                                   options:NSDirectoryEnumerationSkipsPackageDescendants| NSDirectoryEnumerationSkipsHiddenFiles
                                                                              errorHandler:nil];
    
    NSMutableArray *files = [NSMutableArray array];
    for (NSURL *theURL in dirEnumerator) {
        NSNumber *isDirectory;
        [theURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (![isDirectory boolValue]) {
            [files addObject:theURL.path];
        }
    }

    NSArray *formatted = [self.formatter formatFiles:files error:error];
    
    return (formatted.count == files.count);
}

@end
