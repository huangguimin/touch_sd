import SwiftUI

/// A CGImage drawn with hard pixels at a fixed scale (sensor images are tiny).
public struct PixelImage: View {
    let image: CGImage?
    var scale: CGFloat = 1

    public init(image: CGImage?, scale: CGFloat = 1) {
        self.image = image
        self.scale = scale
    }

    public var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        }
    }
}

/// A CGImage scaled to fit the space it gets.
public struct FitImage: View {
    let image: CGImage?
    var placeholder = ""

    public init(image: CGImage?, placeholder: String = "") {
        self.image = image
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.medium)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(placeholder).foregroundColor(.secondary)
            }
        }
    }
}

/// Enrolment progress ring, animated on change (as Android's enrolment page).
public struct Ring: View {
    let value: Double
    let text: String
    var done = false
    var size: CGFloat = 150

    public init(value: Double, text: String, done: Bool = false, size: CGFloat = 150) {
        self.value = value
        self.text = text
        self.done = done
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: size * 0.063)
            Circle()
                .trim(from: 0, to: value)
                .stroke(done ? Color(red: 0.09, green: 0.5, blue: 0.22) : Color(red: 0.1, green: 0.45, blue: 0.91),
                        style: StrokeStyle(lineWidth: size * 0.063, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text("\(Int((value * 100).rounded()))%").font(.system(size: size * 0.16, weight: .bold))
                Text(text).font(.system(size: size * 0.07))
            }
        }
        .frame(width: size, height: size)
        .padding(size * 0.07)
    }
}

/// Integer field with stepper, for the forms.
public struct IntField: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...10000

    public init(label: String, value: Binding<Int>, range: ClosedRange<Int> = 0...10000) {
        self.label = label
        _value = value
        self.range = range
    }

    public var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: $value, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}
