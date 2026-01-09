import { Controller } from "@hotwired/stimulus"

const formatUnit = (unit: string, _value: number | string): string => {
  return unit[0]
}

export default class CountdownController extends Controller {
  static targets = ["time"]
  static values = { endTime: String, baseUnit: String }

  declare readonly timeTarget: HTMLElement
  declare endTimeValue: string
  declare baseUnitValue: string

  private interval: ReturnType<typeof setInterval> | null = null

  connect(): void {
    this.startCountdown()
  }

  startCountdown(): void {
    this.updateCountdown()

    this.interval = setInterval(() => {
      this.updateCountdown()
    }, 1000)
  }

  updateCountdown(): void {
    const now = new Date()
    const distance = Date.parse(this.endTimeValue) - now.getTime()

    const oneSecond = 1000
    const oneMinute = oneSecond * 60
    const oneHour = oneMinute * 60
    const oneDay = oneHour * 24
    const oneYear = oneDay * 365

    const years = Math.floor(distance / oneYear)
    const days = Math.floor((distance % oneYear) / oneDay)
    const hours = Math.floor((distance % oneDay) / oneHour)
    const minutes = Math.floor((distance % oneHour) / oneMinute)
    const secondsNum = Math.floor((distance % oneMinute) / oneSecond)
    const seconds: string | number = secondsNum < 10 ? `0${secondsNum}` : secondsNum

    let values: (string | number)[] = [years, days, hours, minutes, seconds]
    let keys = ["years", "days", "hours", "minutes", "seconds"]
    const nonZeroIndex = values.findIndex((value) => Number(value) > 0)
    const unitIndex = keys.indexOf(this.baseUnitValue || "seconds")
    keys = keys.slice(nonZeroIndex, unitIndex + 1)
    values = values.slice(nonZeroIndex, unitIndex + 1)

    const textChunks = keys.map((key, index) => `${values[index]}${formatUnit(key, values[index])}`)

    this.timeTarget.innerHTML = textChunks.join(" : ")

    if (distance < 0) {
      if (this.interval) {
        clearInterval(this.interval)
      }
      this.timeTarget.innerText = "0"
    }
  }

  disconnect(): void {
    if (this.interval) {
      clearInterval(this.interval)
    }
  }
}
