// `turbo:load` fires on initial page load AND on every Turbo navigation, so
// the init runs every time the form is rendered (whether reached via a full
// page load or a Turbo nav from elsewhere). The early-return guard below
// handles the case where the elements don't exist on the current page.
document.addEventListener("turbo:load", function () {
  const passwordField = document.getElementById("password-field") as HTMLInputElement | null
  const passwordConfirmationField = document.getElementById("password-confirmation-field") as HTMLInputElement | null
  const passwordFeedback = document.getElementById("password-feedback")
  const passwordConfirmationFeedback = document.getElementById("password-confirmation-feedback")
  const submitButton = document.getElementById("submit-button") as HTMLButtonElement | null

  // Only initialize if all elements exist
  if (!passwordField || !passwordConfirmationField || !passwordFeedback || !passwordConfirmationFeedback || !submitButton) {
    return
  }

  function validatePassword(): boolean {
    const password = passwordField!.value
    const isLengthValid = password.length >= 14

    if (password.length === 0) {
      passwordFeedback!.innerHTML = ""
      passwordFeedback!.className = "password-feedback"
    } else if (isLengthValid) {
      passwordFeedback!.innerHTML = `<div class="password-constraint met">✓</div>`
      passwordFeedback!.className = "password-feedback valid"
    } else {
      const remainingChars = 14 - password.length
      passwordFeedback!.innerHTML = `<div class="password-constraint unmet"><span class="char-count">${remainingChars}</span> more character${remainingChars > 1 ? "s" : ""} needed</div>`
      passwordFeedback!.className = `password-feedback invalid`
    }

    return isLengthValid
  }

  function validatePasswordConfirmation(): boolean {
    const password = passwordField!.value
    const confirmation = passwordConfirmationField!.value
    const passwordsMatch = password === confirmation && confirmation.length > 0

    if (confirmation.length === 0) {
      passwordConfirmationFeedback!.innerHTML = ""
      passwordConfirmationFeedback!.className = "password-feedback"
    } else if (passwordsMatch) {
      passwordConfirmationFeedback!.innerHTML = `<div class="password-constraint met">✓</div>`
      passwordConfirmationFeedback!.className = "password-feedback valid"
    } else {
      passwordConfirmationFeedback!.innerHTML = `<div class="password-constraint unmet">Passwords must match</div>`
      passwordConfirmationFeedback!.className = `password-feedback invalid`
    }

    return passwordsMatch
  }

  function updateSubmitButton(): void {
    const isPasswordValid = validatePassword()
    const isConfirmationValid = validatePasswordConfirmation()
    const allFieldsValid = isPasswordValid && isConfirmationValid
    submitButton!.disabled = !allFieldsValid
  }

  passwordField.addEventListener("input", function () {
    validatePassword()
    validatePasswordConfirmation() // Re-validate confirmation when password changes
    updateSubmitButton()
  })

  passwordConfirmationField.addEventListener("input", function () {
    validatePasswordConfirmation()
    updateSubmitButton()
  })

  // Initial validation
  updateSubmitButton()
})
