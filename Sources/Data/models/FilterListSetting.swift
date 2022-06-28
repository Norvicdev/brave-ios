//
//  FilterListSetting.swift
//  
//
//  Created by Jacob on 2022-07-14.
//

import Foundation
import CoreData
import Shared

private let log = Logger.browserLogger

public final class FilterListSetting: NSManagedObject, CRUD {
  @NSManaged public var uuid: String
  @NSManaged public var isEnabled: Bool
  
  public class func allSettings() -> [FilterListSetting] {
    return all(context: DataController.viewContext) ?? []
  }
  
  public class func create(forUUID uuid: String, isEnabled: Bool) -> FilterListSetting {
    var newSetting: FilterListSetting!

    // Settings are usually accesed on view context, but when the setting doesn't exist,
    // we have to switch to a background context to avoid writing on view context(bad practice).
    let writeContext = DataController.newBackgroundContext()

    writeContext.performAndWait {
      newSetting = FilterListSetting(entity: FilterListSetting.entity(writeContext), insertInto: writeContext)
      newSetting.uuid = uuid
      newSetting.isEnabled = isEnabled

      if writeContext.hasChanges {
        do {
          try writeContext.save()
        } catch {
          log.error("FilterListSetting save error: \(error)")
        }
      }
    }

    guard let settingOnCorrectContext = DataController.viewContext.object(with: newSetting.objectID) as? FilterListSetting else {
      assertionFailure("Could not retrieve domain on correct context")
      return newSetting
    }

    return settingOnCorrectContext
  }
  
  public func save() {
    let writeContext = DataController.viewContext
    
    writeContext.performAndWait {
      if writeContext.hasChanges {
        do {
          try writeContext.save()
        } catch {
          log.error("FilterListSetting save error: \(error)")
        }
      }
    }
  }
  
  // Currently required, because not `syncable`
  public static func entity(_ context: NSManagedObjectContext) -> NSEntityDescription {
    return NSEntityDescription.entity(forEntityName: "FilterListSetting", in: context)!
  }
}
