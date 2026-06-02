import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import ListFormController from "./list_form_controller"

describe("ListFormController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("list-form", ListFormController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  async function mount(opts: { visibility: string; addPolicy: string }) {
    document.body.innerHTML = `
      <form data-controller="list-form">
        <select data-list-form-target="visibility"
                data-action="change->list-form#sync">
          <option value="public" ${opts.visibility === "public" ? "selected" : ""}>Public</option>
          <option value="private" ${opts.visibility === "private" ? "selected" : ""}>Private</option>
        </select>
        <select data-list-form-target="addPolicy">
          <option value="owner_only" ${opts.addPolicy === "owner_only" ? "selected" : ""}>Owner only</option>
          <option value="self_add" ${opts.addPolicy === "self_add" ? "selected" : ""}>Self-add</option>
          <option value="members_add" ${opts.addPolicy === "members_add" ? "selected" : ""}>Members add</option>
          <option value="anyone_add" ${opts.addPolicy === "anyone_add" ? "selected" : ""}>Anyone add</option>
        </select>
      </form>
    `
    await new Promise((resolve) => setTimeout(resolve, 0))
    return {
      visibility: document.querySelector("[data-list-form-target='visibility']") as HTMLSelectElement,
      addPolicy: document.querySelector("[data-list-form-target='addPolicy']") as HTMLSelectElement,
    }
  }

  function disabledOptionValues(select: HTMLSelectElement): string[] {
    return Array.from(select.options).filter((o) => o.disabled).map((o) => o.value)
  }

  it("on connect with private + non-owner_only, snaps add_policy to owner_only", async () => {
    const { addPolicy } = await mount({ visibility: "private", addPolicy: "anyone_add" })
    expect(addPolicy.value).toBe("owner_only")
  })

  it("on connect with public, all add_policy options are enabled", async () => {
    const { addPolicy } = await mount({ visibility: "public", addPolicy: "owner_only" })
    expect(disabledOptionValues(addPolicy)).toEqual([])
  })

  it("on connect with private, only owner_only is enabled", async () => {
    const { addPolicy } = await mount({ visibility: "private", addPolicy: "owner_only" })
    expect(disabledOptionValues(addPolicy)).toEqual(["self_add", "members_add", "anyone_add"])
  })

  it("switching visibility to private disables non-owner_only options and snaps the value", async () => {
    const { visibility, addPolicy } = await mount({ visibility: "public", addPolicy: "anyone_add" })
    expect(addPolicy.value).toBe("anyone_add")
    expect(disabledOptionValues(addPolicy)).toEqual([])

    visibility.value = "private"
    visibility.dispatchEvent(new Event("change", { bubbles: true }))

    expect(addPolicy.value).toBe("owner_only")
    expect(disabledOptionValues(addPolicy)).toEqual(["self_add", "members_add", "anyone_add"])
  })

  it("switching back to public re-enables all options without changing the current value", async () => {
    const { visibility, addPolicy } = await mount({ visibility: "private", addPolicy: "owner_only" })

    visibility.value = "public"
    visibility.dispatchEvent(new Event("change", { bubbles: true }))

    expect(addPolicy.value).toBe("owner_only")
    expect(disabledOptionValues(addPolicy)).toEqual([])
  })
})
