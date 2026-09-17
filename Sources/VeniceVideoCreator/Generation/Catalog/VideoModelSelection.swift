struct VideoModelSelection {
    var selected: VideoModelConfig?

    func resolve(in models: [VideoModelConfig]) -> VideoModelConfig? {
        guard let selected else { return models.first }
        return models.first { $0.id == selected.id } ?? selected
    }

    func validationError(in models: [VideoModelConfig], isLoaded: Bool) -> String? {
        guard isLoaded else { return "Wait for Models to finish loading, or refresh Models in Settings." }
        guard let model = resolve(in: models), models.contains(where: { $0.id == model.id }) else {
            return "The selected video model is unavailable. Select an available model before generating."
        }
        return nil
    }
}
