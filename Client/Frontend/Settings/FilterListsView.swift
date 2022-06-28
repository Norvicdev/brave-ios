//
//  FilterListsView.swift
//  
//
//  Created by Jacob on 2022-07-05.
//

import SwiftUI
import Strings
import Data
import DesignSystem

struct FilterListsView: View {
  @ObservedObject private var subscriber = FilterListResourceSubscriber.shared
  
  var body: some View {
    List {
      Section {
        ForEach(subscriber.filterListWrappers) { filterListWrapper in
          Toggle(isOn: $subscriber.filterListWrappers[getIndex(for: filterListWrapper)!].isEnabled) {
            VStack(alignment: .leading) {
              Text(filterListWrapper.filterList.title)
              Text(filterListWrapper.filterList.description)
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }.toggleStyle(SwitchToggleStyle(tint: .accentColor))
        }
      } header: {
        Text(Strings.filterListsDescription)
      }
      
    }.navigationTitle(Strings.filterLists)
  }
  
  func getIndex(for filterListWrapper: FilterListResourceSubscriber.FilterListWrapper) -> Int? {
    return subscriber.filterListWrappers.firstIndex(where: { $0.id == filterListWrapper.id })
  }
}

#if DEBUG
struct FilterListsView_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      FilterListsView()
    }
    .previewLayout(.sizeThatFits)
  }
}
#endif
