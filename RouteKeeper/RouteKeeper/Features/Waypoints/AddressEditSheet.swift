//
//  AddressEditSheet.swift
//  RouteKeeper
//
//  Sheet for viewing and editing the structured address fields stored on a waypoint.
//
//  All eleven user-editable address fields are shown as labelled TextFields.
//  Tapping Done invokes `onDone` with the updated AddressData; tapping Cancel
//  discards all changes.  Empty fields are normalised to nil by the caller.
//

import SwiftUI

struct AddressEditSheet: View {
    /// The address as it stands when the sheet opens.
    let initialAddress: AddressData
    /// Called with the final AddressData when the user taps Done.
    let onDone: (AddressData) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Field state

    @State private var houseNumber   = ""
    @State private var road          = ""
    @State private var suburb        = ""
    @State private var neighbourhood = ""
    @State private var city          = ""
    @State private var municipality  = ""
    @State private var county        = ""
    @State private var stateDistrict = ""
    @State private var state         = ""
    @State private var postcode      = ""
    @State private var country       = ""

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Address")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    row("House Number",  text: $houseNumber)
                    row("Road",          text: $road)
                    row("Suburb",        text: $suburb)
                    row("Neighbourhood", text: $neighbourhood)
                    row("City",          text: $city)
                    row("Municipality",  text: $municipality)
                    row("County",        text: $county)
                    row("State District", text: $stateDistrict)
                    row("State",         text: $state)
                    row("Postcode",      text: $postcode)
                    row("Country",       text: $country)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 380)
        .frame(minHeight: 440)
        .onAppear { populate() }
    }

    // MARK: - Row view

    private func row(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Helpers

    private func populate() {
        houseNumber   = initialAddress.houseNumber   ?? ""
        road          = initialAddress.road          ?? ""
        suburb        = initialAddress.suburb        ?? ""
        neighbourhood = initialAddress.neighbourhood ?? ""
        city          = initialAddress.city          ?? ""
        municipality  = initialAddress.municipality  ?? ""
        county        = initialAddress.county        ?? ""
        stateDistrict = initialAddress.stateDistrict ?? ""
        state         = initialAddress.state         ?? ""
        postcode      = initialAddress.postcode      ?? ""
        country       = initialAddress.country       ?? ""
    }

    private func save() {
        let updated = AddressData(
            houseNumber:   houseNumber.trimmedOrNil,
            road:          road.trimmedOrNil,
            suburb:        suburb.trimmedOrNil,
            neighbourhood: neighbourhood.trimmedOrNil,
            city:          city.trimmedOrNil,
            municipality:  municipality.trimmedOrNil,
            county:        county.trimmedOrNil,
            stateDistrict: stateDistrict.trimmedOrNil,
            state:         state.trimmedOrNil,
            postcode:      postcode.trimmedOrNil,
            country:       country.trimmedOrNil,
            countryCode:   initialAddress.countryCode  // preserve; not shown in UI
        )
        onDone(updated)
        dismiss()
    }
}

// MARK: - String helper

private extension String {
    /// Returns the trimmed string, or `nil` if it is empty after trimming.
    var trimmedOrNil: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
