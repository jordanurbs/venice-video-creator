import SwiftUI

struct VideoBudgetControl: View {
    @Binding var maximumUSD: Double

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("1080P spending cap (USD)")
            TextField("USD", value: $maximumUSD, format: .number)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("1080P spending cap in USD")
                .accessibilityIdentifier("generation.highResolutionBudget")
            Text("Each 1080P attempt requires a fresh quote within this cap. Includes retries.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
        .foregroundStyle(AppTheme.Text.primaryColor)
    }
}
