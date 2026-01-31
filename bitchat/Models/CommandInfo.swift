//
// CommandsInfo.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: String, Identifiable {
    case block
    case clear
    case hug
    case message = "dm"
    case slap
    case unblock
    case who
    case favorite
    case unfavorite
    case agent
    case agentconfig
    case agentset
    case agenton
    case agentoff
    case agentquality
    case agentruntime
    case agentgateway
    case agenttoken
    case agenttimeout
    case agentstream
    case agentsession
    
    var id: String { rawValue }
    
    var alias: String { "/" + rawValue }
    
    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite:
            return "<" + String(localized: "content.input.nickname_placeholder") + ">"
        case .agent:
            return "<role> <prompt>"
        case .agentconfig:
            return nil
        case .agentset:
            return "<role> <model> [quality] [hash]"
        case .agenton, .agentoff:
            return nil
        case .agentquality:
            return "<0-100>"
        case .agentruntime:
            return "<echo|gateway>"
        case .agentgateway:
            return "<url>"
        case .agenttoken:
            return "<token>"
        case .agenttimeout:
            return "<seconds>"
        case .agentstream:
            return "<on|off>"
        case .agentsession:
            return "<list|resume|new|end> [id]"
        case .clear, .who:
            return nil
        }
    }
    
    var description: String {
        switch self {
        case .block:        String(localized: "content.commands.block")
        case .clear:        String(localized: "content.commands.clear")
        case .hug:          String(localized: "content.commands.hug")
        case .message:      String(localized: "content.commands.message")
        case .slap:         String(localized: "content.commands.slap")
        case .unblock:      String(localized: "content.commands.unblock")
        case .who:          String(localized: "content.commands.who")
        case .favorite:     String(localized: "content.commands.favorite")
        case .unfavorite:   String(localized: "content.commands.unfavorite")
        case .agent:        "send agent request"
        case .agentconfig:  "show agent config"
        case .agentset:     "set agent role/model"
        case .agenton:      "enable agent"
        case .agentoff:     "disable agent"
        case .agentquality: "set agent quality"
        case .agentruntime: "set agent runtime"
        case .agentgateway: "set agent gateway URL"
        case .agenttoken:   "set agent gateway token"
        case .agenttimeout: "set agent runtime timeout"
        case .agentstream: "toggle agent response streaming"
        case .agentsession: "manage agent sessions"
        }
    }
    
    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let baseCommands: [CommandInfo] = [
            .agent, .agentconfig, .agentset, .agenton, .agentoff, .agentquality,
            .agentruntime, .agentgateway, .agenttoken, .agenttimeout, .agentstream, .agentsession,
            .block, .unblock, .clear, .hug, .message, .slap, .who
        ]
        if isGeoPublic || isGeoDM {
            return baseCommands + [.favorite, .unfavorite]
        }
        return baseCommands
    }
}
