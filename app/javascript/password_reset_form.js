document.addEventListener('DOMContentLoaded', function() {
  const passwordField = document.getElementById('password-field');
  const passwordConfirmationField = document.getElementById('password-confirmation-field');
  const passwordFeedback = document.getElementById('password-feedback');
  const passwordConfirmationFeedback = document.getElementById('password-confirmation-feedback');
  const submitButton = document.getElementById('submit-button');

  function validatePassword() {
    const password = passwordField.value;
    const isLengthValid = password.length >= 14;

    if (password.length === 0) {
      passwordFeedback.innerHTML = '';
      passwordFeedback.className = 'password-feedback';
    } else if (isLengthValid) {
      passwordFeedback.innerHTML = `<div class="password-constraint met">✓</div>`;
      passwordFeedback.className = 'password-feedback valid';
    } else {
      const remainingChars = 14 - password.length;
      passwordFeedback.innerHTML = `<div class="password-constraint unmet"><span class="char-count">${remainingChars}</span> more character${remainingChars > 1 ? 's' : ''} needed</div>`;
      passwordFeedback.className = `password-feedback invalid`;
    }

    return isLengthValid;
  }

  function validatePasswordConfirmation() {
    const password = passwordField.value;
    const confirmation = passwordConfirmationField.value;
    const passwordsMatch = password === confirmation && confirmation.length > 0;

    if (confirmation.length === 0) {
      passwordConfirmationFeedback.innerHTML = '';
      passwordConfirmationFeedback.className = 'password-feedback';
    } else if (passwordsMatch) {
      passwordConfirmationFeedback.innerHTML = `<div class="password-constraint met">✓</div>`;
      passwordConfirmationFeedback.className = 'password-feedback valid';
    } else {
      passwordConfirmationFeedback.innerHTML = `<div class="password-constraint unmet">Passwords must match</div>`;
      passwordConfirmationFeedback.className = `password-feedback invalid`;
    }

    return passwordsMatch;
  }

  function updateSubmitButton() {
    const isPasswordValid = validatePassword();
    const isConfirmationValid = validatePasswordConfirmation();
    const allFieldsValid = isPasswordValid && isConfirmationValid;
    submitButton.disabled = !allFieldsValid;
  }

  passwordField.addEventListener('input', function() {
    validatePassword();
    validatePasswordConfirmation(); // Re-validate confirmation when password changes
    updateSubmitButton();
  });

  passwordConfirmationField.addEventListener('input', function() {
    validatePasswordConfirmation();
    updateSubmitButton();
  });

  // Initial validation
  updateSubmitButton();
});
