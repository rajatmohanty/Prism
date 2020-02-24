//
//  TemplateParser.swift
//  Prism
//
//  Created by Shai Mishali on 23/05/2019.
//  Copyright © 2019 Gett. All rights reserved.
//

import Foundation
import ZeplinAPI

/// Provides a mechanism to parse and process Prism-flavored
/// templates into a provided format by extracting tokens
/// and transformations, and resolving and applying them.
///
//
//                                     ┌───────────────┐
//                                   ┌─▶    Tokens     │
//                                   │ │  (resolved)   │
//  ┌─────────────────┐   ┌────────┐ │ └───────┬───────┘   ┌──────────────┐
//  │                 │   │        │ │         │         ┌─▶ Processed    │
//  │ .prism Template ────▶ Parser ├─┘         │         │ │       Output │
//  │                 │   │        │   ┌───────▼───────┐ │ └──────────────┘
//  └─────────────────┘   └────────┘   │Transformations│ │
//                                     │   (applied)   ├─┘
//                                     └───────────────┘

public class TemplateParser {
    let project: ProjectAssets
    let configuration: Configuration?

    /// Initialize a Template Parser object.
    ///
    /// - parameter project: Prism Project.
    /// - parameter configuration: Configuration object (Optional).
    public init(project: ProjectAssets,
                configuration: Configuration? = nil) {
        self.project = project
        self.configuration = configuration
    }

    public func parse(template: String) throws -> String {
        /// Make sure the project doesn't contain any reserved identities.
        /// Otherwise, throw an error.
        var allReservedIdentities = Set<String>()

        if let reservedColors = configuration?.reservedColors {
            let allColorIdentities = Set(project.colors.flatMap { color in
                Project.AssetIdentity.Style.allCases.map { $0.identifier(for: color.identity) }
            })

            let reservedColorsSet = Set(reservedColors)
            let usedReservedColors = reservedColorsSet.intersection(allColorIdentities)

            allReservedIdentities.formUnion(usedReservedColors)
        }

        if let reservedTextStyles = configuration?.reservedTextStyles {
            let allTextStyleIdentities = Set(project.textStyles.flatMap { textStyle in
                Project.AssetIdentity.Style.allCases.map { $0.identifier(for: textStyle.identity) }
            })

            let reservedTextStylesSet = Set(reservedTextStyles)
            let usedReservedTextStyles = reservedTextStylesSet.intersection(allTextStyleIdentities)

            allReservedIdentities.formUnion(usedReservedTextStyles)
        }

        guard allReservedIdentities.isEmpty else {
            throw Error.prohibitedIdentities(identities: allReservedIdentities.joined(separator: ", "))
        }

        /// If everything's OK, try to recrusively parse the provided template.
        return try recursivelyParse(lines: template.components(separatedBy: "\n"))
                    .joined(separator: "\n")
    }

    /// Recursively parse an block of template lines, producing a processed
    /// array of lines are token resolution and transformations.
    ///
    /// If the method finds an iterable directive such as {{% FOR textStyle %}},
    /// it would recursively parse that specific block, providing each text
    /// style (or color) to the method.
    ///
    /// - parameter lines: An array of lines to parse
    /// - parameter color: An optional color. Usually provided within a color loop.
    /// - parameter textStyle: An optional text style. Usually provided within a text style loop.
    ///
    /// - returns: An array of processed lines.
    private func recursivelyParse(lines: [String],
                                  color: Color? = nil,
                                  textStyle: TextStyle? = nil) throws -> [String] {
        var output = [String]()
        var currentLineIdx = 0

        while currentLineIdx < lines.count {
            let currentLine = lines[currentLineIdx]

            // Detect a FOR loop
            if let forBlock = try detectBlock(keyword: "FOR",
                                              lines: lines,
                                              currentLineIdx: currentLineIdx) {
                switch forBlock.identifier {
                case "color":
                    let colorLoop = try project.colors
                                               .reduce(into: [String]()) { result, color in
                                                result.append(contentsOf: try recursivelyParse(lines: forBlock.body,
                                                                                               color: color))
                    }
                    
                    output.append(contentsOf: colorLoop)
                case "textStyle":
                    let textStyleLoop = try project.textStyles
                                                   .reduce(into: [String]()) { result, textStyle in
                        result.append(contentsOf: try recursivelyParse(lines: forBlock.body,
                                                                       textStyle: textStyle))
                    }

                    output.append(contentsOf: textStyleLoop)
                default:
                    throw Error.unknownLoop(identifier: forBlock.identifier)
                }

                currentLineIdx = forBlock.endLine + 1
                continue
            }

            /// Make sure this line has some sort of Token.
            /// Otherwise, simply add it to the output.
            guard currentLine.contains("{{%") else {
                output.append(currentLine)
                currentLineIdx += 1
                continue
            }
            
            /// Detect an IF condition
            if let condition = try detectBlock(keyword: "IF",
                                               end: "ENDIF",
                                               lines: lines,
                                               currentLineIdx: currentLineIdx) {
                let token: Token
                if let color = color {
                    token = try Token(rawColorToken: condition.identifier, color: color)
                } else if let textStyle = textStyle {
                    token = try Token(rawTextStyleToken: condition.identifier,
                                      textStyle: textStyle,
                                      colors: project.colors)
                } else {
                    throw Error.unknownToken(token: condition.identifier)
                }
                
                let tokenHasValue = token.stringValue(transformations: []) != nil
                
                if let preBody = condition.preBody,
                   let postBody = condition.postBody {
                    var inlineItems = tokenHasValue ? condition.body : []
                    inlineItems.insert(preBody, at: 0)
                    inlineItems.append(postBody)
                    
                    let final = inlineItems.filter { !$0.isEmpty }.joined()
                    
                    if !final.trimmingCharacters(in: .whitespaces).isEmpty {
                        output.append(contentsOf: try recursivelyParse(lines: [final],
                                                                       color: color,
                                                                       textStyle: textStyle))
                    }
                } else if tokenHasValue {
                    output.append(contentsOf: try recursivelyParse(lines: condition.body,
                                                                   color: color,
                                                                   textStyle: textStyle))
                }

                currentLineIdx = condition.endLine + 1
                continue
            }

            /// The current line has at least a single token that
            /// should be resolved.
            output.append(try resolveTokens(line: currentLine, color: color, textStyle: textStyle))
            currentLineIdx += 1
        }

        return output
    }

    /// Resolve any tokens in the provided line, replacing them
    /// with the correct underlying values.
    ///
    /// - parameter line: A string line.
    /// - parameter color: A color, usually provided if the line is part of a colors loop.
    /// - parameter textStyle: A color, usually provided if the line is part of a text styles loop.
    ///
    /// - returns: Provided line with resolved tokens.
    private func resolveTokens(line: String,
                               color: Color?,
                               textStyle: TextStyle?) throws -> String {
        let lineLength = line.count
        var output = line
        var tokens = [String: String?]()

        let tokensRegex = try NSRegularExpression(pattern: #"\{\{%(.*?)%\}\}"#)
        let tokenMatches = tokensRegex.matches(in: line, options: .init(),
                                               range: NSRange(location: 0, length: lineLength))

        for tokenMatch in tokenMatches {
            let fullToken = (line as NSString).substring(with: tokenMatch.range(at: 1))
            let transformations: [Transformation]
            let token: String

            if fullToken.contains("|") {
                let tokenPieces = fullToken.components(separatedBy: "|")
                token = tokenPieces[0]
                transformations = try tokenPieces[1...].compactMap(Transformation.init)

                output = output.replacingOccurrences(of: fullToken,
                                                     with: token)
            } else {
                token = fullToken
                transformations = []
            }

            if let color = color {
                tokens[token] = try Token(rawColorToken: token, color: color).stringValue(transformations: transformations)
            } else if let textStyle = textStyle {
                tokens[token] = try Token(rawTextStyleToken: token, textStyle: textStyle, colors: project.colors).stringValue(transformations: transformations)
            }
        }
        
        // Apply all tokens to the output
        return tokens.reduce(output) { output, token in
            let value = token.value ?? ""
            return output.replacingOccurrences(of: "{{%\(token.key)%}}", with: value)
        }
    }
}

extension TemplateParser {
    enum Error: Swift.Error, CustomStringConvertible {
        /// An unknown FOR loop identifier error
        case unknownLoop(identifier: String)

        /// An open block with no closing
        case openBlock(keyword: String, identifier: String)

        /// An unknown template token error
        case unknownToken(token: String)

        /// Trying to parse a text style's color while color has
        /// no identity / name, or while a color doesn't match from
        /// the project's colors
        case missingColorForTextStyle(TextStyle)

        /// One or more prohibited identities were used
        case prohibitedIdentities(identities: String)
        
        /// An unknown transformation was applied
        case unknownTransformation(String)

        var description: String {
            switch self {
            case .unknownLoop(let identifier):
                return "Illegal FOR loop identifier '\(identifier)'"
            case let .openBlock(keyword, identifier):
                return "Detected \(keyword) block '\(identifier)' with no closing"
            case .unknownToken(let token):
                return "Illegal token in template '\(token)'"
            case .missingColorForTextStyle(let textStyle):
                let color = textStyle.color
                return "Text Style \(textStyle.name) has a color RGBA(\(color.r), \(color.g), \(color.b), \(color.a)), but it has no matching color identity"
            case .prohibitedIdentities(let identities):
                return "Prohibited identities '\(identities)' can't be used"
            case .unknownTransformation(let name):
                return "There is no transformation called '\(name)'"
            }
        }
    }
}