//
//  FilterList.swift
//  
//
//  Created by Jacob on 2022-07-18.
//

import Foundation

struct FilterList: Decodable {
  enum Format: String, Decodable {
    case standard = "Standard"
  }
  
  enum CodingKeys: String, CodingKey {
    case uuid, url, title, format, langs, componentId, description = "desc"
  }
  
  let uuid: String
  let url: URL
  let title: String
  let format: Format
  let langs: [String]
  let description: String
  let componentId: String
}
